-- Manual, non-destructive fee security checks. Run only after the schema and RPC migrations
-- are reviewed and applied to an isolated database with synthetic accounts.
-- This script deliberately contains no real student identifiers or payment data.
begin;

do $$
begin
  if to_regclass('public.fee_payment_submissions') is null
     or to_regclass('public.fee_ledger_entries') is null
     or to_regclass('public.fee_receipts') is null then
    raise exception 'Fees schema is not installed';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='fee_principal_confirm_payment'
  ) then raise exception 'Principal confirmation RPC missing'; end if;
  if to_regprocedure('public.fee_student_submissions_by_session(text)') is null then
    raise exception 'Student payment status RPC missing';
  end if;
  if to_regprocedure('public.fee_admin_discount_queue()') is null then
    raise exception 'Admin discount queue RPC missing';
  end if;
  if to_regprocedure('public.fee_admin_list_academic_years()') is null
     or to_regprocedure('public.fee_admin_search_students(text)') is null
     or to_regprocedure('public.fee_admin_search_fee_accounts(text)') is null then
    raise exception 'Admin fee setup/search RPC missing';
  end if;
  if has_function_privilege('anon','public.fee_admin_search_students(text)','EXECUTE')
     or has_function_privilege('anon','public.fee_admin_discount_queue()','EXECUTE') then
    raise exception 'Admin-only fee RPC must not be executable by anon';
  end if;
  if not has_function_privilege('anon','public.fee_student_submissions_by_session(text)','EXECUTE') then
    raise exception 'Session-token student payment status RPC must be callable through the student gateway';
  end if;
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='fee_payment_submissions' and c.relrowsecurity
  ) then raise exception 'RLS is not enabled on payment submissions'; end if;
  if has_table_privilege('anon','public.fee_payment_submissions','SELECT')
     or has_table_privilege('authenticated','public.fee_payment_submissions','SELECT') then
    raise exception 'Direct SELECT on fee payment submissions must remain revoked';
  end if;
  if has_table_privilege('anon','public.fee_ledger_entries','INSERT')
     or has_table_privilege('authenticated','public.fee_ledger_entries','INSERT') then
    raise exception 'Direct INSERT on fee ledger must remain revoked';
  end if;
  if has_table_privilege('anon','public.fee_receipts','INSERT')
     or has_table_privilege('authenticated','public.fee_receipts','INSERT') then
    raise exception 'Direct INSERT on receipts must remain revoked';
  end if;
end $$;

rollback;
