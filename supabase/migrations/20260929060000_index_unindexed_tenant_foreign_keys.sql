-- Add indexes for foreign-key columns identified in the isolated database audit.
-- These support joins, tenant-scoped lookups, and referential actions.
-- Staged source only; review query plans and write overhead before production rollout.
begin;

create index if not exists attendance_punches_staff_tenant_fk_idx
  on public.attendance_punches (staff_id, tenant_id);

create index if not exists leave_requests_staff_tenant_fk_idx
  on public.leave_requests (staff_id, tenant_id);

create index if not exists platform_admins_created_by_fk_idx
  on public.platform_admins (created_by);

create index if not exists school_applications_reviewed_by_fk_idx
  on public.school_applications (reviewed_by);

create index if not exists staff_id_cards_staff_tenant_fk_idx
  on public.staff_id_cards (staff_id, tenant_id);

create index if not exists tenant_memberships_user_id_fk_idx
  on public.tenant_memberships (user_id);

commit;
