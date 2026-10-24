-- Manual post-migration security regression test.
-- Run only AFTER the anonymous-grant migration has been applied to a disposable
-- test database cloned from the production schema. This script reads metadata only.
-- It does not read student/staff rows and makes no database changes.
do $security_assertions$
declare
  v_table text;
  v_tables text[] := array[
    'admin_users','attendance_punches','attendance_qr_sessions','audit_logs',
    'leave_requests','staff','student_attendance','student_calendar_events',
    'student_class_assignments','student_homework','student_leave_requests',
    'student_notices','student_report_cards','student_roster','student_timetable'
  ];
begin
  foreach v_table in array v_tables loop
    if to_regclass(format('public.%I', v_table)) is null then
      raise exception 'Security test setup error: required production table public.% is missing', v_table;
    end if;

    if has_table_privilege('anon', format('public.%I', v_table), 'SELECT')
       or has_table_privilege('anon', format('public.%I', v_table), 'INSERT')
       or has_table_privilege('anon', format('public.%I', v_table), 'UPDATE')
       or has_table_privilege('anon', format('public.%I', v_table), 'DELETE')
       or has_table_privilege('anon', format('public.%I', v_table), 'TRUNCATE')
       or has_table_privilege('anon', format('public.%I', v_table), 'REFERENCES')
       or has_table_privilege('anon', format('public.%I', v_table), 'TRIGGER') then
      raise exception 'SECURITY FAILURE: anon still has a direct table privilege on public.%', v_table;
    end if;

    if not exists (
      select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = v_table
        and c.relkind = 'r'
        and c.relrowsecurity
    ) then
      raise exception 'SECURITY REVIEW REQUIRED: RLS is not enabled on public.%', v_table;
    end if;
  end loop;

  raise notice 'PASS: all 15 expected tables exist, have RLS enabled, and deny direct anon table privileges.';
end;
$security_assertions$;

-- Follow this metadata assertion with separate application tests in the test
-- environment: student login/session, staff login, admin/teacher workflows,
-- attendance, leave requests, fee submission, and cross-student isolation.
-- Do not use real student or employee records in negative-access tests.
