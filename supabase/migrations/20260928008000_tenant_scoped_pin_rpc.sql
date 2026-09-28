-- Tenant-scope authenticated PIN changes and remove anonymous PIN verification.
-- Depends on tenant membership helpers in 20260928006000_tenant_membership_rls.sql.
-- Staged only; validate self/admin PIN workflows in an isolated database.
begin;

create or replace function public.set_staff_pin(p_staff_id text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_tenant_id uuid;
  v_email text := lower(coalesce((select auth.jwt() ->> 'email'), ''));
begin
  if auth.uid() is null or nullif(v_email, '') is null then
    return false;
  end if;

  select s.tenant_id into v_tenant_id
  from public.staff s
  where s.id = p_staff_id
    and s.status = 'ACTIVE';

  if v_tenant_id is null then
    return false;
  end if;

  if not (
    exists (
      select 1 from public.staff s
      where s.id = p_staff_id
        and s.tenant_id = v_tenant_id
        and lower(s.email) = v_email
    )
    or private.has_active_tenant_role(v_tenant_id, 'SCHOOL_ADMIN')
  ) then
    return false;
  end if;

  return private.set_staff_pin_internal(p_staff_id, p_pin);
end;
$function$;

revoke all on function public.verify_staff_pin(text,text) from anon;
revoke all on function public.set_staff_pin(text,text) from anon;
grant execute on function public.set_staff_pin(text,text) to authenticated;

commit;
