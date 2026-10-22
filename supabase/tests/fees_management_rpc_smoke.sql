-- End-to-end RPC smoke test using synthetic users and a synthetic student only.
-- The transaction is rolled back; never run against production data.
begin;

insert into public.student_roster(id,school_code,student_name,enroll_no,class_name,section,status)
values ('11111111-1111-4111-8111-111111111111','ashiana','Synthetic Student','TEST-001','II','A','ACTIVE')
on conflict (id) do nothing;

select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);
select set_config('request.jwt.claim.fee_admin','true',true);

do $$
declare
  v_year uuid;
  v_structure uuid;
  v_account uuid;
  v_submission uuid;
  v_result text;
  v_summary record;
begin
  v_year := public.fee_admin_save_academic_year('2098-2099','2098-04-01','2099-03-31',true);
  v_structure := public.fee_admin_save_structure(v_year,'II','Tuition',10000,true,'2098-04-10');
  v_account := public.fee_admin_assign_student_account(v_year,'11111111-1111-4111-8111-111111111111');

  select * into v_summary
  from public.fee_student_summary_by_session('synthetic-student-session-token-000000000000')
  where fee_account_id=v_account;
  if not found or v_summary.total_due_paise <> 10000 or v_summary.balance_paise <> 10000 then
    raise exception 'Synthetic student fee summary mismatch';
  end if;

  v_submission := public.fee_submit_payment_by_session(
    'synthetic-student-session-token-000000000000',v_account,5000,
    'SYNTHETIC-UPI-REF-001',v_account::text||'/synthetic-proof.png','Synthetic test only'
  );
  v_result := public.fee_admin_review_payment(v_submission,true,null);
  if v_result <> 'PENDING_PRINCIPAL' then raise exception 'Admin review transition failed'; end if;

  insert into public.fee_principal_approvers(user_id,school_code,is_enabled,assigned_by)
  values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','ashiana',true,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
  on conflict (user_id) do update set is_enabled=true;

  perform set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true);
  perform set_config('request.jwt.claim.fee_admin','false',true);
  v_result := public.fee_principal_confirm_payment(v_submission,true,null);

  if v_result is null or v_result not like 'APS-%' then
    raise exception 'Principal confirmation did not issue a receipt';
  end if;
  if (select count(*) from public.fee_ledger_entries where payment_submission_id=v_submission and entry_type='PAYMENT' and amount_paise=5000) <> 1 then
    raise exception 'Expected exactly one payment ledger entry after Principal confirmation';
  end if;
  if (select count(*) from public.fee_receipts where payment_submission_id=v_submission and receipt_number=v_result) <> 1 then
    raise exception 'Expected exactly one receipt after Principal confirmation';
  end if;
  if (select status from public.fee_payment_submissions where id=v_submission) <> 'CONFIRMED' then
    raise exception 'Payment did not reach CONFIRMED state';
  end if;

  -- A second confirmation must fail and must not duplicate the ledger/receipt.
  begin
    perform public.fee_principal_confirm_payment(v_submission,true,null);
    raise exception 'Duplicate Principal confirmation unexpectedly succeeded';
  exception when others then
    if sqlerrm = 'Duplicate Principal confirmation unexpectedly succeeded' then raise; end if;
  end;
end $$;

rollback;
