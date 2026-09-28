-- Tenant-scoped staff identity and tenant-consistent staff relations.
-- Depends on 20260928000000_multitenant_foundation.sql; staged only.
begin;

-- The foundation migration backfills every existing row before these are enforced.
alter table public.staff alter column tenant_id set not null;
alter table public.attendance_punches alter column tenant_id set not null;
alter table public.leave_requests alter column tenant_id set not null;
alter table public.audit_logs alter column tenant_id set not null;
alter table public.admin_users alter column tenant_id set not null;
alter table public.attendance_qr_sessions alter column tenant_id set not null;
alter table public.staff_id_cards alter column tenant_id set not null;

-- Employee IDs are school-local, while staff primary IDs remain globally unique.
alter table public.staff drop constraint if exists staff_emp_id_key;
alter table public.staff add constraint staff_tenant_emp_id_key unique (tenant_id, emp_id);
alter table public.staff add constraint staff_id_tenant_key unique (id, tenant_id);

-- Prevent records from linking a staff ID to a different tenant.
alter table public.attendance_punches drop constraint if exists attendance_punches_staff_id_fkey;
alter table public.attendance_punches add constraint attendance_punches_staff_tenant_fkey
  foreign key (staff_id, tenant_id) references public.staff(id, tenant_id) on delete cascade;

alter table public.leave_requests drop constraint if exists leave_requests_staff_id_fkey;
alter table public.leave_requests add constraint leave_requests_staff_tenant_fkey
  foreign key (staff_id, tenant_id) references public.staff(id, tenant_id) on delete cascade;

alter table public.staff_id_cards drop constraint if exists staff_id_cards_staff_id_fkey;
alter table public.staff_id_cards add constraint staff_id_cards_staff_tenant_fkey
  foreign key (staff_id, tenant_id) references public.staff(id, tenant_id) on delete cascade;

commit;
