-- Allow the trusted verify-attendance Edge Function (service role) to update
-- a staff PIN through the public PostgREST RPC wrapper.
--
-- The previous wrapper only accepted a JWT whose email matched a staff/admin
-- record. The Edge Function deliberately uses the service-role client, whose
-- JWT has role=service_role and no staff email, so the wrapper returned FALSE
-- even after the Edge Function had authenticated the staff member and checked
-- their current PIN.

create or replace function public.set_staff_pin(p_staff_id text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.role()), '') <> 'service_role'
     and not (
       exists (
         select 1
         from public.staff s
         where s.id = p_staff_id
           and lower(s.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
       )
       or exists (
         select 1
         from public.admin_users a
         where lower(a.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
           and a.active
       )
     )
  then
    return false;
  end if;

  return private.set_staff_pin_internal(p_staff_id, p_pin);
end;
$$;

revoke all on function public.set_staff_pin(text, text) from public, anon;
grant execute on function public.set_staff_pin(text, text) to authenticated, service_role;
