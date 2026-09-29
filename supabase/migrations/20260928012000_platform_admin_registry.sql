-- Registry for trusted platform-level school approvers.
-- No administrator is auto-seeded: an operator must provision an authorized
-- Auth user ID through a controlled database-admin process.
begin;

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete restrict,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);

alter table public.platform_admins enable row level security;

drop policy if exists platform_admins_read_own on public.platform_admins;
create policy platform_admins_read_own
  on public.platform_admins
  for select to authenticated
  using (user_id = (select auth.uid()) and active = true);

revoke all on public.platform_admins from anon, authenticated;
grant select on public.platform_admins to authenticated;

-- Replace the prior hard-coded approver-email policy after the registry exists.
drop policy if exists school_applications_platform_approver_read
  on public.school_applications;
create policy school_applications_platform_approver_read
  on public.school_applications
  for select to authenticated
  using (exists (
    select 1
    from public.platform_admins pa
    where pa.user_id = (select auth.uid())
      and pa.active = true
  ));

commit;
