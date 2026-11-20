-- Non-destructive checks for role/module permission schema and fee confirmation gates.
begin;
do $$
begin
  if to_regclass('public.role_module_permissions') is null
     or to_regclass('public.role_module_permission_audit') is null then
    raise exception 'Role permission tables are missing';
  end if;
  if to_regprocedure('public.check_role_module_permission(text,text)') is null
     or to_regprocedure('public.admin_list_role_module_permissions()') is null
     or to_regprocedure('public.admin_set_role_module_permission(text,text,boolean,boolean,boolean,boolean,boolean,boolean)') is null then
    raise exception 'Role permission RPCs are missing';
  end if;
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='role_module_permissions' and c.relrowsecurity
  ) then raise exception 'RLS is not enabled on role_module_permissions'; end if;
  if has_table_privilege('anon','public.role_module_permissions','SELECT')
     or has_table_privilege('authenticated','public.role_module_permissions','SELECT')
     or has_table_privilege('authenticated','public.role_module_permissions','UPDATE') then
    raise exception 'Role permissions must not be directly readable or writable by clients'; end if;
  if has_function_privilege('anon','public.admin_list_role_module_permissions()','EXECUTE')
     or has_function_privilege('anon','public.admin_set_role_module_permission(text,text,boolean,boolean,boolean,boolean,boolean,boolean)','EXECUTE') then
    raise exception 'Admin permission RPCs must not be executable by anon'; end if;
  if not exists(select 1 from public.role_module_permissions where role_key='PRINCIPAL' and module_key='fee_confirmations' and can_view and can_approve) then
    raise exception 'Principal fee confirmation defaults are missing'; end if;
  if to_regprocedure('public.fee_principal_confirm_payment(uuid,boolean,text)') is null
     or to_regprocedure('public.fee_principal_payment_queue()') is null then
    raise exception 'Principal fee confirmation RPCs are missing'; end if;
end $$;
rollback;
