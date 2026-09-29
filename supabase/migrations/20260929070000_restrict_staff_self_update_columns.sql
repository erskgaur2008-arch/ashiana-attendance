-- Restrict authenticated staff self-service updates to profile-safe columns.
-- School administrators retain their existing tenant-scoped update workflow.
-- Service-role / trusted database operations are unaffected (no end-user auth.uid()).
-- Staged source only; test profile, avatar, and admin-edit flows in isolation.
begin;

create or replace function private.enforce_staff_self_update_columns()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_email text := lower(coalesce((select auth.jwt() ->> 'email'), ''));
begin
  -- Trusted server-side operations do not carry an end-user identity.
  if auth.uid() is null then
    return new;
  end if;

  -- Row identity is immutable for every end-user update, including admins.
  -- Keep this outside the admin bypass so roster edits cannot re-key a staff row.
  if new.id is distinct from old.id or new.tenant_id is distinct from old.tenant_id then
    raise exception 'Staff identity and tenant are immutable'
      using errcode = '42501';
  end if;

  -- Active school administrators retain tenant-scoped roster editing.
  if private.has_active_tenant_role(old.tenant_id, 'SCHOOL_ADMIN') then
    return new;
  end if;

  -- Self-service is only for the active staff member matching this Auth identity.
  if v_email = ''
     or old.status <> 'ACTIVE'
     or lower(coalesce(old.email, '')) <> v_email
     or not private.has_active_tenant_role(old.tenant_id, 'STAFF') then
    raise exception 'Staff profile update is not authorized'
      using errcode = '42501';
  end if;

  -- Keep all fields immutable except the profile fields used by the staff
  -- profile form and staff avatar upload path.
  if (to_jsonb(new) - array['name','gender','dob','phone','address','avatar_url'])
     is distinct from
     (to_jsonb(old) - array['name','gender','dob','phone','address','avatar_url']) then
    raise exception 'Staff may update only personal profile fields'
      using errcode = '42501';
  end if;

  return new;
end;
$function$;

drop trigger if exists enforce_staff_self_update_columns on public.staff;
create trigger enforce_staff_self_update_columns
before update on public.staff
for each row execute function private.enforce_staff_self_update_columns();

commit;
