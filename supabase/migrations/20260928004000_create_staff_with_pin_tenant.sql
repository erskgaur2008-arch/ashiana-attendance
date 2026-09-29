-- Tenant-aware staff creation RPC (staged only; not applied).
-- The trusted Edge Function supplies the tenant only after validating the caller's
-- active SCHOOL_ADMIN membership. Auth user creation remains an external step.
begin;

create or replace function public.create_staff_with_pin_tenant(
  p_tenant_id uuid,
  p_id text,
  p_emp_id text,
  p_name text,
  p_department text,
  p_role text,
  p_email text,
  p_status text,
  p_pin text
)
returns public.staff
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_staff public.staff;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;

  if p_tenant_id is null
     or nullif(trim(p_id), '') is null
     or nullif(trim(p_emp_id), '') is null
     or nullif(trim(p_name), '') is null
     or nullif(trim(p_email), '') is null then
    raise exception 'Tenant, staff id, employee id, name and email are required';
  end if;

  if not exists (
    select 1 from public.tenants t
    where t.id = p_tenant_id and t.status = 'active'
  ) then
    raise exception 'Tenant is not active';
  end if;

  insert into public.staff (
    id, tenant_id, emp_id, name, department, role, email, pin_hash, status
  )
  values (
    p_id, p_tenant_id, upper(trim(p_emp_id)), trim(p_name),
    nullif(trim(p_department), ''), nullif(trim(p_role), ''),
    lower(trim(p_email)), extensions.crypt(p_pin, extensions.gen_salt('bf')),
    case when upper(coalesce(p_status, 'ACTIVE')) = 'INACTIVE' then 'INACTIVE' else 'ACTIVE' end
  )
  returning * into v_staff;

  return v_staff;
end;
$function$;

revoke all on function public.create_staff_with_pin_tenant(uuid,text,text,text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.create_staff_with_pin_tenant(uuid,text,text,text,text,text,text,text,text) to service_role;

commit;
