-- Defense-in-depth: remove anonymous SQL privileges from tenant business tables.
-- RLS remains the row-level authorization boundary for authenticated users.
-- Staged only; verify API behavior in an isolated database before applying.
begin;

revoke all privileges on table
  public.admin_users,
  public.attendance_punches,
  public.attendance_qr_sessions,
  public.audit_logs,
  public.leave_requests,
  public.staff,
  public.staff_id_cards
from anon;

commit;
