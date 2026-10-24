-- Security hardening: remove direct anonymous table privileges from sensitive
-- school records. Existing role/session RPCs must continue enforcing identity
-- and authorization internally.
--
-- This migration intentionally does NOT change bucket visibility or revoke EXECUTE
-- from SECURITY DEFINER RPCs. Those changes require client-flow updates and
-- function-by-function compatibility tests.
--
-- IMPORTANT: validate application compatibility in an isolated environment
-- before applying this migration to production.

REVOKE ALL PRIVILEGES ON TABLE
  public.admin_users,
  public.attendance_punches,
  public.attendance_qr_sessions,
  public.audit_logs,
  public.leave_requests,
  public.staff,
  public.student_attendance,
  public.student_calendar_events,
  public.student_class_assignments,
  public.student_homework,
  public.student_leave_requests,
  public.student_notices,
  public.student_report_cards,
  public.student_roster,
  public.student_timetable
FROM anon;

-- Post-migration verification query (run separately after migration):
-- SELECT table_name, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public'
--   AND grantee = 'anon'
--   AND table_name IN (
--     'admin_users', 'attendance_punches', 'attendance_qr_sessions', 'audit_logs',
--     'leave_requests', 'staff', 'student_attendance', 'student_calendar_events',
--     'student_class_assignments', 'student_homework', 'student_leave_requests',
--     'student_notices', 'student_report_cards', 'student_roster', 'student_timetable'
--   );
--
-- Expected result: zero rows for these 15 tables.
-- Do not add broad grants back to anon. Use narrowly scoped RPCs with explicit
-- validation, or authenticated RLS policies, for required application operations.
