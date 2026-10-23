-- Student pending-fee reminders: schedule stages, in-app inbox, and token-scoped reads.
begin;

alter table public.fee_reminder_attempts
  add column if not exists reminder_stage text not null default 'DUE_DATE'
    check (reminder_stage in ('PRE_DUE_3D','DUE_DATE','OVERDUE_7D'));

do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid='public.fee_reminder_attempts'::regclass and contype='u'
      and pg_get_constraintdef(oid) like '%fee_account_id%installment_id%reminder_kind%due_date%'
  loop
    execute format('alter table public.fee_reminder_attempts drop constraint %I', c.conname);
  end loop;
end $$;

create unique index if not exists fee_reminder_attempts_stage_unique
  on public.fee_reminder_attempts(fee_account_id, installment_id, reminder_kind, reminder_stage, due_date);

create table if not exists public.fee_student_reminders (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana' check (school_code='ashiana'),
  student_id uuid not null references public.student_roster(id) on delete cascade,
  fee_account_id uuid not null references public.student_fee_accounts(id) on delete cascade,
  installment_id uuid not null references public.fee_installments(id) on delete cascade,
  reminder_stage text not null check (reminder_stage in ('PRE_DUE_3D','DUE_DATE','OVERDUE_7D')),
  title text not null,
  message text not null,
  amount_due_paise bigint not null check (amount_due_paise >= 0),
  due_date date not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique(student_id, installment_id, reminder_stage)
);
create index if not exists fee_student_reminders_student_created_idx
  on public.fee_student_reminders(student_id, created_at desc);
alter table public.fee_student_reminders enable row level security;
revoke all on public.fee_student_reminders from public, anon, authenticated;

-- Returns only currently actionable installment reminders. Approved account-level discounts
-- are allocated to installments oldest-first. Pending payments suppress reminders entirely.
create or replace function public.fee_reminder_candidates(p_today date default (now() at time zone 'Asia/Kolkata')::date)
returns table (
  student_id uuid, fee_account_id uuid, installment_id uuid, enroll_no text,
  student_name text, class_name text, section text, fee_name text, amount_due_paise bigint,
  due_date date, reminder_stage text
)
language sql security definer set search_path = ''
as $function$
  with account_discount as (
    select a.id fee_account_id,
      coalesce(sum(d.amount_paise) filter (where d.status='APPROVED'),0)::bigint discount_paise
    from public.student_fee_accounts a
    left join public.fee_discount_requests d on d.fee_account_id=a.id
    where a.school_code='ashiana'
    group by a.id
  ), item_values as (
    select a.id fee_account_id, a.student_id, i.id installment_id, i.amount_paise,
      i.due_date, fs.fee_name, s.enroll_no, s.student_name, s.class_name, s.section,
      coalesce(ad.discount_paise,0) discount_paise,
      coalesce((select sum(p.amount_paise) from public.fee_payment_submissions p
        where p.installment_id=i.id and p.status='CONFIRMED'),0)::bigint paid_paise,
      coalesce((select sum(p.amount_paise) from public.fee_payment_submissions p
        where p.installment_id=i.id and p.status in ('PENDING_ADMIN','PENDING_PRINCIPAL')),0)::bigint pending_paise,
      coalesce(sum(i.amount_paise) over (
        partition by a.id order by i.due_date, fs.fee_name, i.id
        rows between unbounded preceding and 1 preceding
      ),0)::bigint prior_installments_paise
    from public.student_fee_accounts a
    join public.student_roster s on s.id=a.student_id and s.status='ACTIVE' and s.school_code='ashiana'
    join public.fee_installments i on i.fee_account_id=a.id
    join public.fee_structures fs on fs.id=i.fee_structure_id
    left join account_discount ad on ad.fee_account_id=a.id
    where a.school_code='ashiana'
  ), balances as (
    select v.*,
      greatest(0, least(v.amount_paise,
        v.discount_paise - v.prior_installments_paise))::bigint allocated_discount_paise
    from item_values v
  ), eligible as (
    select b.*,
      case
        when b.due_date = p_today + 3 then 'PRE_DUE_3D'
        when b.due_date = p_today then 'DUE_DATE'
        when b.due_date <= p_today - 7 then 'OVERDUE_7D'
      end as stage
    from balances b
    where b.pending_paise=0
      and greatest(0,b.amount_paise-b.paid_paise-b.allocated_discount_paise)>0
  )
  select e.student_id, e.fee_account_id, e.installment_id, e.enroll_no,
    e.student_name, e.class_name, e.section, e.fee_name,
    greatest(0,e.amount_paise-e.paid_paise-e.allocated_discount_paise)::bigint,
    e.due_date, e.stage
  from eligible e
  where e.stage is not null;
$function$;

create or replace function public.fee_student_reminders_by_session(p_token text)
returns table (
  id uuid, installment_id uuid, title text, message text, amount_due_paise bigint,
  due_date date, reminder_stage text, created_at timestamptz, read_at timestamptz
)
language plpgsql security definer set search_path = ''
as $function$
declare v_student uuid;
begin
  v_student := public.student_session_student_id(p_token);
  if v_student is null then raise exception 'Invalid or expired student session'; end if;
  return query
    select r.id, r.installment_id, r.title, r.message, r.amount_due_paise,
      r.due_date, r.reminder_stage, r.created_at, r.read_at
    from public.fee_student_reminders r
    where r.student_id=v_student and r.school_code='ashiana'
    order by r.created_at desc
    limit 50;
end;
$function$;

revoke all on function public.fee_reminder_candidates(date) from public, anon, authenticated;
grant execute on function public.fee_reminder_candidates(date) to service_role;
revoke all on function public.fee_student_reminders_by_session(text) from public, authenticated;
grant execute on function public.fee_student_reminders_by_session(text) to anon;

commit;
