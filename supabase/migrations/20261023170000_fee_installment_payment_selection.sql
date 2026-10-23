-- Add installment-specific student payment selection without changing existing fee/payment records.
begin;

alter table public.fee_payment_submissions
  add column if not exists installment_id uuid references public.fee_installments(id);

create index if not exists fee_payment_installment_status_idx
  on public.fee_payment_submissions(installment_id, status, created_at);

drop function if exists public.fee_student_summary_by_session(text);
create function public.fee_student_summary_by_session(p_token text)
returns table (
  fee_account_id uuid,
  academic_year_id uuid,
  academic_year_label text,
  student_id uuid,
  total_due_paise bigint,
  total_paid_paise bigint,
  discount_paise bigint,
  balance_paise bigint,
  fee_items jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
begin
  v_student := public.student_session_student_id(p_token);
  if v_student is null then
    raise exception 'Invalid or expired student session';
  end if;

  return query
  select
    a.id,
    y.id,
    y.label,
    a.student_id,
    coalesce((select sum(i.amount_paise) from public.fee_installments i where i.fee_account_id=a.id),0)::bigint,
    coalesce((select sum(l.amount_paise) from public.fee_ledger_entries l where l.fee_account_id=a.id),0)::bigint,
    coalesce((select sum(d.amount_paise) from public.fee_discount_requests d where d.fee_account_id=a.id and d.status='APPROVED'),0)::bigint,
    greatest(
      0,
      coalesce((select sum(i.amount_paise) from public.fee_installments i where i.fee_account_id=a.id),0)
      - coalesce((select sum(d.amount_paise) from public.fee_discount_requests d where d.fee_account_id=a.id and d.status='APPROVED'),0)
      - coalesce((select sum(l.amount_paise) from public.fee_ledger_entries l where l.fee_account_id=a.id),0)
    )::bigint,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'installment_id', i.id,
        'fee_structure_id', fs.id,
        'fee_name', fs.fee_name,
        'class_name', fs.class_name,
        'amount_paise', i.amount_paise,
        'due_date', i.due_date,
        'paid_paise', coalesce((
          select sum(p.amount_paise) from public.fee_payment_submissions p
          where p.installment_id=i.id and p.status='CONFIRMED'
        ),0),
        'pending_paise', coalesce((
          select sum(p.amount_paise) from public.fee_payment_submissions p
          where p.installment_id=i.id and p.status in ('PENDING_ADMIN','PENDING_PRINCIPAL')
        ),0),
        'balance_paise', greatest(
          0,
          i.amount_paise
          - coalesce((select sum(p.amount_paise) from public.fee_payment_submissions p
            where p.installment_id=i.id and p.status='CONFIRMED'),0)
          - coalesce((select sum(p.amount_paise) from public.fee_payment_submissions p
            where p.installment_id=i.id and p.status in ('PENDING_ADMIN','PENDING_PRINCIPAL')),0)
        )
      ) order by i.due_date, fs.fee_name)
      from public.fee_installments i
      join public.fee_structures fs on fs.id=i.fee_structure_id
      where i.fee_account_id=a.id
    ), '[]'::jsonb)
  from public.student_fee_accounts a
  join public.fee_academic_years y on y.id=a.academic_year_id
  where a.student_id=v_student and a.school_code='ashiana'
  order by y.starts_on desc;
end;
$$;

drop function if exists public.fee_submit_payment_by_session(text,uuid,bigint,text,text,text);
create function public.fee_submit_payment_by_session(
  p_token text,
  p_fee_account_id uuid,
  p_installment_id uuid,
  p_amount_paise bigint,
  p_upi_reference text,
  p_proof_object_path text,
  p_student_note text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student uuid;
  v_submission uuid;
  v_balance bigint;
begin
  v_student := public.student_session_student_id(p_token);
  if v_student is null then
    raise exception 'Invalid or expired student session';
  end if;
  if p_amount_paise is null or p_amount_paise <= 0 or p_amount_paise > 1000000000 then
    raise exception 'Payment amount is invalid';
  end if;
  if p_upi_reference is null or length(trim(p_upi_reference)) not between 6 and 120 then
    raise exception 'A valid UPI/reference ID is required';
  end if;
  if p_proof_object_path is null or length(trim(p_proof_object_path)) < 8
     or p_proof_object_path like '/%' or p_proof_object_path like '%..%' then
    raise exception 'A valid private proof object path is required';
  end if;

  perform 1
  from public.student_fee_accounts a
  where a.id=p_fee_account_id and a.student_id=v_student and a.school_code='ashiana'
  for update;
  if not found then
    raise exception 'Fee account not found';
  end if;

  perform 1
  from public.fee_installments i
  where i.id=p_installment_id and i.fee_account_id=p_fee_account_id
  for update;
  if not found then
    raise exception 'Selected fee installment does not belong to this student fee account';
  end if;

  select greatest(
    0,
    i.amount_paise
    - coalesce((select sum(p.amount_paise) from public.fee_payment_submissions p
      where p.installment_id=i.id and p.status='CONFIRMED'),0)
    - coalesce((select sum(p.amount_paise) from public.fee_payment_submissions p
      where p.installment_id=i.id and p.status in ('PENDING_ADMIN','PENDING_PRINCIPAL')),0)
  )::bigint
  into v_balance
  from public.fee_installments i
  where i.id=p_installment_id and i.fee_account_id=p_fee_account_id;

  if v_balance <= 0 then
    raise exception 'No outstanding balance remains for this installment';
  end if;
  if p_amount_paise > v_balance then
    raise exception 'Payment amount exceeds the selected installment balance';
  end if;

  insert into public.fee_payment_submissions(
    fee_account_id, installment_id, amount_paise, upi_reference, proof_object_path,
    student_note, submitted_by_student_id
  ) values (
    p_fee_account_id, p_installment_id, p_amount_paise, trim(p_upi_reference),
    trim(p_proof_object_path), nullif(trim(coalesce(p_student_note,'')),''), v_student
  ) returning id into v_submission;

  insert into public.fee_audit_log(school_code, action, entity_type, entity_id, details)
  values ('ashiana','PAYMENT_SUBMITTED','fee_payment_submission',v_submission,
    jsonb_build_object('fee_account_id',p_fee_account_id,'installment_id',p_installment_id,'amount_paise',p_amount_paise));

  return v_submission;
exception when unique_violation then
  raise exception 'This UPI/reference ID has already been submitted';
end;
$$;

revoke all on function public.fee_student_summary_by_session(text) from public, authenticated;
grant execute on function public.fee_student_summary_by_session(text) to anon;
revoke all on function public.fee_submit_payment_by_session(text,uuid,uuid,bigint,text,text,text) from public, authenticated;
grant execute on function public.fee_submit_payment_by_session(text,uuid,uuid,bigint,text,text,text) to anon;

commit;
