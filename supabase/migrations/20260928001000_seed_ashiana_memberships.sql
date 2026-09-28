-- Seed memberships for existing Supabase Auth users after tenant foundation.
-- This migration is staged on the feature branch and is not applied to production.
begin;

with ashiana as (
  select id as tenant_id from public.tenants where slug = 'ashiana'
),
known_users as (
  select u.id as user_id,
         case when exists (
           select 1 from public.admin_users a
           where lower(a.email) = lower(u.email) and a.active = true
         ) then 'SCHOOL_ADMIN' else 'STAFF' end as role
  from auth.users u
  where u.email is not null
    and (
      exists (select 1 from public.admin_users a where lower(a.email) = lower(u.email) and a.active = true)
      or exists (select 1 from public.staff s where lower(s.email) = lower(u.email) and s.status = 'ACTIVE')
    )
)
insert into public.tenant_memberships (tenant_id, user_id, role, active)
select ashiana.tenant_id, known_users.user_id, known_users.role, true
from ashiana cross join known_users
on conflict (tenant_id, user_id) do update
set role = excluded.role,
    active = true;

-- Membership records are managed only by trusted server-side provisioning.
revoke insert, update, delete, truncate, references, trigger
on public.tenant_memberships from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
on public.tenants from anon, authenticated;

commit;
