-- Staff Auth password lock
--
-- Staff never sign in with an Auth password any more (the verify-attendance
-- function mints sessions after checking the PIN server-side). This makes the
-- Auth password of every staff account permanently RANDOM, even if some other
-- code (for example the reset-staff-pin function, which still tries to set a
-- "derived" password) writes a guessable one.
--
-- Run this AFTER the new verify-attendance function is deployed.
-- Admin accounts (public.admin_users) are excluded: they keep their real password.

create or replace function private.lock_staff_auth_password()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (
       coalesce(new.raw_user_meta_data ->> 'account_type', '') = 'staff'
       or exists (select 1 from public.staff s where lower(s.email) = lower(coalesce(new.email, '')))
     )
     and not exists (
       select 1 from public.admin_users a
        where a.active and lower(a.email) = lower(coalesce(new.email, ''))
     )
  then
    if tg_op = 'INSERT' or new.encrypted_password is distinct from old.encrypted_password then
      new.encrypted_password := extensions.crypt(
        gen_random_uuid()::text || gen_random_uuid()::text,
        extensions.gen_salt('bf')
      );
    end if;
  end if;
  return new;
end;
$$;

revoke all on function private.lock_staff_auth_password() from public, anon, authenticated;

drop trigger if exists lock_staff_auth_password on auth.users;
create trigger lock_staff_auth_password
  before insert or update of encrypted_password on auth.users
  for each row execute function private.lock_staff_auth_password();

-- ONE-TIME RESET: replace every existing staff password (which may be the old
-- guessable "EduPunch!<id>!<PIN>") with a random one. Fires the trigger above.
update auth.users u
   set encrypted_password = extensions.crypt(
         gen_random_uuid()::text || gen_random_uuid()::text,
         extensions.gen_salt('bf')
       )
 where (
         coalesce(u.raw_user_meta_data ->> 'account_type', '') = 'staff'
         or exists (select 1 from public.staff s where lower(s.email) = lower(coalesce(u.email, '')))
       )
   and not exists (
         select 1 from public.admin_users a
          where a.active and lower(a.email) = lower(coalesce(u.email, ''))
       );
