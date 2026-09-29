-- Multi-tenant foundation (staged only; not applied to production).
-- Existing application policies remain in place until tenant-aware client and
-- Edge Functions are deployed together in a later migration.
begin;

create table if not exists public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  status text not null default 'active' check (status in ('active','suspended')),
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.tenant_memberships (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('SCHOOL_ADMIN','STAFF')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);

insert into public.tenants (name, slug)
values ('Ashiana Public School', 'ashiana')
on conflict (slug) do nothing;

alter table public.staff add column if not exists tenant_id uuid references public.tenants(id);
alter table public.attendance_punches add column if not exists tenant_id uuid references public.tenants(id);
alter table public.leave_requests add column if not exists tenant_id uuid references public.tenants(id);
alter table public.audit_logs add column if not exists tenant_id uuid references public.tenants(id);
alter table public.admin_users add column if not exists tenant_id uuid references public.tenants(id);
alter table public.attendance_qr_sessions add column if not exists tenant_id uuid references public.tenants(id);
alter table public.staff_id_cards add column if not exists tenant_id uuid references public.tenants(id);

update public.staff set tenant_id = (select id from public.tenants where slug='ashiana') where tenant_id is null;
update public.attendance_punches set tenant_id = (select id from public.tenants where slug='ashiana') where tenant_id is null;
update public.leave_requests set tenant_id = (select id from public.tenants where slug='ashiana') where tenant_id is null;
update public.audit_logs set tenant_id = (select id from public.tenants where slug='ashiana') where tenant_id is null;
update public.admin_users set tenant_id = (select id from public.tenants where slug='ashiana') where tenant_id is null;
update public.attendance_qr_sessions set tenant_id = (select id from public.tenants where slug='ashiana') where tenant_id is null;
update public.staff_id_cards set tenant_id = (select id from public.tenants where slug='ashiana') where tenant_id is null;

create index if not exists staff_tenant_id_idx on public.staff(tenant_id);
create index if not exists attendance_punches_tenant_date_idx on public.attendance_punches(tenant_id, attendance_date);
create index if not exists leave_requests_tenant_idx on public.leave_requests(tenant_id);
create index if not exists audit_logs_tenant_idx on public.audit_logs(tenant_id);
create index if not exists admin_users_tenant_idx on public.admin_users(tenant_id);
create index if not exists attendance_qr_sessions_tenant_idx on public.attendance_qr_sessions(tenant_id);
create index if not exists staff_id_cards_tenant_idx on public.staff_id_cards(tenant_id);

alter table public.tenants enable row level security;
alter table public.tenant_memberships enable row level security;

drop policy if exists "tenant_members_read_own" on public.tenant_memberships;
create policy "tenant_members_read_own" on public.tenant_memberships
for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "tenant_read_membership" on public.tenants;
create policy "tenant_read_membership" on public.tenants
for select to authenticated
using (exists (
  select 1 from public.tenant_memberships m
  where m.tenant_id = tenants.id
    and m.user_id = (select auth.uid())
    and m.active = true
));

revoke all on public.tenants from anon, authenticated;
revoke all on public.tenant_memberships from anon, authenticated;
grant select on public.tenants to authenticated;
grant select on public.tenant_memberships to authenticated;

commit;
