-- Forward-only correction for Fees Management already-applied schema.
-- Reserve payment submissions awaiting review when validating a new discount.
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

commit;
