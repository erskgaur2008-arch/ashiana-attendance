-- Security hardening: remove direct anonymous table privileges from sensitive
-- school records. Existing role/session RPCs remain available and must continue
-- enforcing identity and authorization internally.
--
-- This migration intentionally does NOT change bucket visibility or revoke EXECUTE
-- from SECURITY DEFINER RPCs: those changes require client-flow updates and
-- function-by-function compatibility tests to avoid breaking student login,
-- attendance, staff workflows, fee submissions, or document links.

revoke all privileges on table
  public.admin_users,
  public.attendance_punches,
  public.leave_requests,
  public.staff,
  public.student_attendance,
  public.student_leave_requests,
  public.student_roster
from anon;

-- Verification is deliberately non-destructive. These queries should return
-- no rows for the listed tables and the anon role after this migration:
-- select table_name, privilege_type
-- from information_schema.role_table_grants
-- where table_schema = 'public'
--   and grantee = 'anon'
--   and table_name in (
--     'admin_users','attendance_punches','leave_requests','staff',
--     'student_attendance','student_leave_requests','student_roster'
--   );
--
-- Do not add broad grants back to anon. Use narrowly scoped RPCs with explicit
-- validation, or authenticated RLS policies, for required application operations.
