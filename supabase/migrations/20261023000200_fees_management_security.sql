-- Fees Management RPC authorization and two-step payment confirmation.
-- Review before applying to any database. No direct client table grants.
begin;

create or replace function public.fee_student_summary_by_session(p_token text)
returns table (
  fee_account_id uuid, academic_year_id uuid, academic_year_label text,
  student_id uuid, total_due_paise bigint, total_paid_paise bigint,
  discount_paise bigint, balance_paise bigint
)
language plpgsql security definer set search_path = ''
as $$
declare v_student uuid;
begin
  v_student := public.student_session_student_id(p_token);
  if v_student is null then raise exception 'Invalid or expired student session'; end if;
  return query
  select a.id, y.id, y.label, a.student_id,
    coalesce((select sum(i.amount_paise) from public.fee_installments i where i.fee_account_id=a.id),0)::bigint,
    coalesce((select sum(l.amount_paise) from public.fee_ledger_entries l where l.fee_account_id=a.id),0)::bigint,
    coalesce((select sum(d.amount_paise) from public.fee_discount_requests d where d.fee_account_id=a.id and d.status='APPROVED'),0)::bigint,
    greatest(0,
      coalesce((select sum(i.amount_paise) from public.fee_installments i where i.fee_account_id=a.id),0)
      - coalesce((select sum(d.amount_paise) from public.fee_discount_requests d where d.fee_account_id=a.id and d.status='APPROVED'),0)
      - coalesce((select sum(l.amount_paise) from public.fee_ledger_entries l where l.fee_account_id=a.id),0)
    )::bigint
  from public.student_fee_accounts a
  join public.fee_academic_years y on y.id=a.academic_year_id
  where a.student_id=v_student and a.school_code='ashiana'
  order by y.starts_on desc;
end;
$$;

create or replace function public.fee_submit_payment_by_session(
  p_token text, p_fee_account_id uuid, p_amount_paise bigint,
  p_upi_reference text, p_proof_object_path text, p_student_note text default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_student uuid; v_submission uuid;
begin
  v_student := public.student_session_student_id(p_token);
  if v_student is null then raise exception 'Invalid or expired student session'; end if;
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
  if not exists (select 1 from public.student_fee_accounts a
      where a.id=p_fee_account_id and a.student_id=v_student and a.school_code='ashiana') then
    raise exception 'Fee account not found';
  end if;
  insert into public.fee_payment_submissions(
    fee_account_id, amount_paise, upi_reference, proof_object_path,
    student_note, submitted_by_student_id
  ) values (
    p_fee_account_id, p_amount_paise, trim(p_upi_reference), trim(p_proof_object_path),
    nullif(trim(coalesce(p_student_note,'')),''), v_student
  ) returning id into v_submission;

  insert into public.fee_audit_log(school_code, action, entity_type, entity_id, details)
  values ('ashiana','PAYMENT_SUBMITTED','fee_payment_submission',v_submission,
    jsonb_build_object('fee_account_id',p_fee_account_id,'amount_paise',p_amount_paise));
  return v_submission;
exception when unique_violation then
  raise exception 'This UPI/reference ID has already been submitted';
end;
$$;

create or replace function public.fee_admin_review_payment(
  p_submission_id uuid, p_approve boolean, p_reason text default null
) returns text
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_status text;
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  select status into v_status from public.fee_payment_submissions
    where id=p_submission_id for update;
  if not found or v_status <> 'PENDING_ADMIN' then raise exception 'Submission is not awaiting Admin review'; end if;
  if p_approve then
    update public.fee_payment_submissions set status='PENDING_PRINCIPAL',
      admin_reviewed_by=v_actor, admin_reviewed_at=now(), rejection_reason=null
    where id=p_submission_id;
  else
    if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Provide a rejection reason'; end if;
    update public.fee_payment_submissions set status='REJECTED',
      admin_reviewed_by=v_actor, admin_reviewed_at=now(), rejection_reason=trim(p_reason)
    where id=p_submission_id;
  end if;
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
    values ('ashiana',v_actor,case when p_approve then 'ADMIN_APPROVED' else 'ADMIN_REJECTED' end,
      'fee_payment_submission',p_submission_id,jsonb_build_object('reason',p_reason));
  return case when p_approve then 'PENDING_PRINCIPAL' else 'REJECTED' end;
end;
$$;

create or replace function public.fee_principal_confirm_payment(
  p_submission_id uuid, p_confirm boolean, p_reason text default null
) returns text
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_submission public.fee_payment_submissions%rowtype;
  v_receipt text;
begin
  if v_actor is null or not exists (
    select 1 from public.fee_principal_approvers p
    where p.user_id=v_actor and p.school_code='ashiana' and p.is_enabled
  ) then raise exception 'Authorized Principal fee permission required'; end if;

  select * into v_submission from public.fee_payment_submissions
    where id=p_submission_id for update;
  if not found or v_submission.status <> 'PENDING_PRINCIPAL' then
    raise exception 'Submission is not awaiting Principal confirmation';
  end if;
  if v_submission.admin_reviewed_by = v_actor then
    raise exception 'The Admin reviewer cannot confirm the same payment as Principal';
  end if;
  if not p_confirm then
    if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'Provide a rejection reason'; end if;
    update public.fee_payment_submissions set status='REJECTED',
      principal_confirmed_by=v_actor, principal_confirmed_at=now(), rejection_reason=trim(p_reason)
    where id=p_submission_id;
    insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
      values ('ashiana',v_actor,'PRINCIPAL_REJECTED','fee_payment_submission',p_submission_id,
        jsonb_build_object('reason',p_reason));
    return 'REJECTED';
  end if;

  update public.fee_payment_submissions set status='CONFIRMED',
    principal_confirmed_by=v_actor, principal_confirmed_at=now(), rejection_reason=null
  where id=p_submission_id;

  insert into public.fee_ledger_entries(
    fee_account_id,payment_submission_id,entry_type,amount_paise,description,created_by
  ) values (
    v_submission.fee_account_id,v_submission.id,'PAYMENT',v_submission.amount_paise,
    'UPI payment confirmed after Admin and Principal review',v_actor
  );

  v_receipt := 'APS-' || to_char(now() at time zone 'Asia/Kolkata','YYYYMMDD') || '-' ||
    upper(substr(replace(v_submission.id::text,'-',''),1,10));
  insert into public.fee_receipts(
    receipt_number,fee_account_id,payment_submission_id,amount_paise,issued_by
  ) values (v_receipt,v_submission.fee_account_id,v_submission.id,v_submission.amount_paise,v_actor);

  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
    values ('ashiana',v_actor,'PRINCIPAL_CONFIRMED_AND_RECEIPT_ISSUED',
      'fee_payment_submission',p_submission_id,jsonb_build_object('receipt_number',v_receipt));
  return v_receipt;
end;
$$;


create or replace function public.fee_student_receipts_by_session(p_token text)
returns table (
  receipt_id uuid, receipt_number text, academic_year_label text,
  amount_paise bigint, issued_at timestamptz
)
language plpgsql security definer set search_path = ''
as $
declare v_student uuid;
begin
  v_student := public.student_session_student_id(p_token);
  if v_student is null then raise exception 'Invalid or expired student session'; end if;
  return query
  select r.id, r.receipt_number, y.label, r.amount_paise, r.issued_at
  from public.fee_receipts r
  join public.student_fee_accounts a on a.id=r.fee_account_id
  join public.fee_academic_years y on y.id=a.academic_year_id
  where a.student_id=v_student and a.school_code='ashiana'
  order by r.issued_at desc;
end;
$;

create or replace function public.fee_admin_payment_queue()
returns table (
  submission_id uuid, student_id uuid, student_name text, enroll_no text,
  class_name text, section text, amount_paise bigint, upi_reference text,
  proof_object_path text, submitted_at timestamptz, status text
)
language plpgsql security definer set search_path = ''
as $
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  return query
  select p.id, s.id, s.student_name::text, s.enroll_no::text, s.class_name::text, s.section::text,
    p.amount_paise, p.upi_reference, p.proof_object_path, p.created_at, p.status
  from public.fee_payment_submissions p
  join public.student_fee_accounts a on a.id=p.fee_account_id
  join public.student_roster s on s.id=a.student_id
  where a.school_code='ashiana' and p.status='PENDING_ADMIN'
  order by p.created_at asc;
end;
$;

create or replace function public.fee_principal_payment_queue()
returns table (
  submission_id uuid, student_id uuid, student_name text, enroll_no text,
  class_name text, section text, amount_paise bigint, upi_reference text,
  proof_object_path text, submitted_at timestamptz, admin_reviewed_at timestamptz
)
language plpgsql security definer set search_path = ''
as $
begin
  if auth.uid() is null or not exists (
    select 1 from public.fee_principal_approvers p
    where p.user_id=auth.uid() and p.school_code='ashiana' and p.is_enabled
  ) then raise exception 'Authorized Principal fee permission required'; end if;
  return query
  select p.id, s.id, s.student_name::text, s.enroll_no::text, s.class_name::text, s.section::text,
    p.amount_paise, p.upi_reference, p.proof_object_path, p.created_at, p.admin_reviewed_at
  from public.fee_payment_submissions p
  join public.student_fee_accounts a on a.id=p.fee_account_id
  join public.student_roster s on s.id=a.student_id
  where a.school_code='ashiana' and p.status='PENDING_PRINCIPAL'
  order by p.admin_reviewed_at asc;
end;
$;

create or replace function public.fee_admin_review_discount(
  p_discount_id uuid, p_approve boolean, p_reason text default null
) returns text
language plpgsql security definer set search_path = ''
as $
declare v_actor uuid := auth.uid(); v_status text; v_account uuid;
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  select d.status, d.fee_account_id into v_status, v_account
  from public.fee_discount_requests d where d.id=p_discount_id for update;
  if not found or v_status <> 'PENDING' then raise exception 'Discount is not awaiting review'; end if;
  update public.fee_discount_requests
    set status=case when p_approve then 'APPROVED' else 'REJECTED' end,
        reviewed_by=v_actor, reviewed_at=now()
  where id=p_discount_id;
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
  values ('ashiana',v_actor,case when p_approve then 'DISCOUNT_APPROVED' else 'DISCOUNT_REJECTED' end,
    'fee_discount_request',p_discount_id,jsonb_build_object('fee_account_id',v_account,'review_reason',p_reason));
  return case when p_approve then 'APPROVED' else 'REJECTED' end;
end;
$;

revoke all on function public.fee_student_summary_by_session(text) from public, authenticated;
revoke all on function public.fee_submit_payment_by_session(text,uuid,bigint,text,text,text) from public, authenticated;
revoke all on function public.fee_admin_review_payment(uuid,boolean,text) from public, anon, authenticated;
revoke all on function public.fee_principal_confirm_payment(uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.fee_student_summary_by_session(text) to anon;
grant execute on function public.fee_submit_payment_by_session(text,uuid,bigint,text,text,text) to anon;
grant execute on function public.fee_admin_review_payment(uuid,boolean,text) to authenticated;
grant execute on function public.fee_principal_confirm_payment(uuid,boolean,text) to authenticated;
revoke all on function public.fee_student_receipts_by_session(text) from public, authenticated;
revoke all on function public.fee_admin_payment_queue() from public, anon;
revoke all on function public.fee_principal_payment_queue() from public, anon;
revoke all on function public.fee_admin_review_discount(uuid,boolean,text) from public, anon;
grant execute on function public.fee_student_receipts_by_session(text) to anon;
grant execute on function public.fee_admin_payment_queue() to authenticated;
grant execute on function public.fee_principal_payment_queue() to authenticated;
grant execute on function public.fee_admin_review_discount(uuid,boolean,text) to authenticated;

commit;
