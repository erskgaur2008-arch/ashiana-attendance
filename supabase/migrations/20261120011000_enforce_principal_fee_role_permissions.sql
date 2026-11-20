-- Require both the existing per-user fee approver grant and the new Principal
-- role/module permission for the two-step payment confirmation workflow.
-- Existing Admin review authorization and fee workflow state transitions are unchanged.
begin;

create or replace function public.fee_principal_payment_queue()
returns table (
  submission_id uuid, student_id uuid, student_name text, enroll_no text,
  class_name text, section text, amount_paise bigint, upi_reference text,
  proof_object_path text, submitted_at timestamptz, admin_reviewed_at timestamptz
)
language plpgsql security definer set search_path = ''
as $function$
begin
  if auth.uid() is null
     or not public.check_role_module_permission('fee_confirmations','view')
     or not exists (
       select 1 from public.fee_principal_approvers p
       where p.user_id=auth.uid() and p.school_code='ashiana' and p.is_enabled
     ) then
    raise exception 'Authorized Principal fee permission required';
  end if;
  return query
  select p.id, s.id, s.student_name::text, s.enroll_no::text, s.class_name::text, s.section::text,
    p.amount_paise, p.upi_reference, p.proof_object_path, p.created_at, p.admin_reviewed_at
  from public.fee_payment_submissions p
  join public.student_fee_accounts a on a.id=p.fee_account_id
  join public.student_roster s on s.id=a.student_id
  where a.school_code='ashiana' and p.status='PENDING_PRINCIPAL'
  order by p.admin_reviewed_at asc;
end;
$function$;

create or replace function public.fee_principal_confirm_payment(
  p_submission_id uuid, p_confirm boolean, p_reason text default null
) returns text
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_submission public.fee_payment_submissions%rowtype;
  v_receipt text;
begin
  if v_actor is null
     or not public.check_role_module_permission('fee_confirmations','approve')
     or not exists (
       select 1 from public.fee_principal_approvers p
       where p.user_id=v_actor and p.school_code='ashiana' and p.is_enabled
     ) then
    raise exception 'Authorized Principal fee permission required';
  end if;

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

revoke all on function public.fee_principal_payment_queue() from public, anon;
revoke all on function public.fee_principal_confirm_payment(uuid,boolean,text) from public, anon;
grant execute on function public.fee_principal_payment_queue() to authenticated;
grant execute on function public.fee_principal_confirm_payment(uuid,boolean,text) to authenticated;

notify pgrst, 'reload schema';
commit;
