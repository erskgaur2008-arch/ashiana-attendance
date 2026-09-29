-- Remove elevated table privileges from browser-facing roles.
-- RLS does not constrain TRUNCATE, and clients do not need TRIGGER or
-- REFERENCES privileges for ordinary application CRUD operations.
-- This migration intentionally preserves SELECT/INSERT/UPDATE/DELETE grants.
-- Staged source only: validate normal app workflows in isolated testing before applying.
begin;

revoke truncate, trigger, references on table
  public.admin_users,
  public.attendance_punches,
  public.attendance_qr_sessions,
  public.audit_logs,
  public.leave_requests,
  public.platform_admins,
  public.school_applications,
  public.staff,
  public.staff_id_cards,
  public.tenant_memberships,
  public.tenants
from anon, authenticated;

commit;
