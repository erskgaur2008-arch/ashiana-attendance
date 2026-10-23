-- Forward-only correction for Fees Management already-applied schema.
-- Reserve payment submissions awaiting review when validating a new discount.
-- Also reject NULL payment decisions so they cannot be treated as approval.
-- Safe to apply after 20261023000200_fees_management_security; does not touch fee data.
begin;

create or replace function public.fee_admin_review_discount(
  p_discount_id uuid, p_approve boolean, p_reason text default null
) returns text
language plpgsql security definer set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_status text;
  v_account uuid;
  v_amount bigint;
  v_balance bigint;
begin
  if p_approve is null then raise exception 'Admin discount decision must be explicit'; end if;
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;

  select d.status, d.fee_account_id, d.amount_paise
    into v_status, v_account, v_amount
  from public.fee_discount_requests d
  where d.id=p_discount_id
  for update;

  if not found or v_status <> 'PENDING' then
    raise exception 'Discount is not awaiting review';
  end if;

  if p_approve then
    -- Serialize discount approval with payment submission for the same fee account.
    perform 1 from public.student_fee_accounts a where a.id=v_account for update;

    select greatest(0,
      coalesce((select sum(i.amount_paise) from public.fee_installments i where i.fee_account_id=v_account),0)
      - coalesce((select sum(d.amount_paise) from public.fee_discount_requests d where d.fee_account_id=v_account and d.status='APPROVED'),0)
      - coalesce((select sum(l.amount_paise) from public.fee_ledger_entries l where l.fee_account_id=v_account),0)
      - coalesce((select sum(p.amount_paise) from public.fee_payment_submissions p
          where p.fee_account_id=v_account and p.status in ('PENDING_ADMIN','PENDING_PRINCIPAL')),0)
    )::bigint into v_balance;

    if v_amount > v_balance then
      raise exception 'Discount exceeds the remaining fee balance after pending payments';
    end if;
  end if;

  update public.fee_discount_requests
    set status=case when p_approve then 'APPROVED' else 'REJECTED' end,
        reviewed_by=v_actor, reviewed_at=now()
  where id=p_discount_id;

  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
  values ('ashiana',v_actor,
    case when p_approve then 'DISCOUNT_APPROVED' else 'DISCOUNT_REJECTED' end,
    'fee_discount_request',p_discount_id,
    jsonb_build_object('fee_account_id',v_account,'review_reason',p_reason));

  return case when p_approve then 'APPROVED' else 'REJECTED' end;
end;
$function$;

create or replace function public.fee_principal_confirm_payment(
  p_submission_id uuid, p_confirm boolean, p_reason text default null
) returns text
language plpgsql security definer set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_submission public.fee_payment_submissions%rowtype;
  v_receipt text;
begin
  if p_confirm is null then raise exception 'Principal payment decision must be explicit'; end if;
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
$function$;

commit;
