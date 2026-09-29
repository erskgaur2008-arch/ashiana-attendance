-- Allow one authenticated admin identity to have a tenant-scoped profile
-- in more than one school. Authorization still requires an active membership
-- and active admin_users row for the selected tenant.
begin;

do $$
begin
  if exists (
    select 1 from public.admin_users where tenant_id is null
  ) then
    raise exception 'Cannot enable multi-school admin profiles: admin_users contains null tenant_id values';
  end if;

  if exists (
    select 1
    from public.admin_users
    group by tenant_id, lower(btrim(email))
    having count(*) > 1
  ) then
    raise exception 'Cannot enable multi-school admin profiles: duplicate admin email exists within a tenant';
  end if;
end;
$$;

alter table public.admin_users
  alter column tenant_id set not null;

-- The legacy primary key is email-only, which prevents an admin from having
-- separate profiles for distinct schools. No table in the staged schema
-- references admin_users by foreign key.
alter table public.admin_users
  drop constraint if exists admin_users_pkey;

alter table public.admin_users
  add constraint admin_users_pkey primary key (tenant_id, email);

-- App and Edge Function lookups are case-insensitive; enforce that same
-- uniqueness contract within each tenant.
create unique index if not exists admin_users_tenant_email_lower_uidx
  on public.admin_users (tenant_id, lower(btrim(email)));

commit;
