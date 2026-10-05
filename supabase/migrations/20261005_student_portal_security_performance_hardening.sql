-- Student portal security/performance hardening.
-- Applied to production as migration: student_portal_security_performance_hardening

create index if not exists student_roster_login_idx
  on public.student_roster (school_code, upper(enroll_no), dob) where status='ACTIVE';
create index if not exists student_attendance_student_date_idx
  on public.student_attendance (school_code, student_id, attendance_date desc);
create index if not exists student_attendance_marked_by_idx
  on public.student_attendance (marked_by);
create index if not exists student_notices_scope_idx
  on public.student_notices (school_code, active, class_name, section, publish_at desc);
create index if not exists student_homework_scope_idx
  on public.student_homework (school_code, active, class_name, section, due_date, created_at desc);
create index if not exists student_timetable_scope_idx
  on public.student_timetable (school_code, active, class_name, section, day_of_week, period_no);
create index if not exists student_leave_student_idx
  on public.student_leave_requests (school_code, student_id, created_at desc);
create index if not exists student_leave_teacher_idx
  on public.student_leave_requests (school_code, lower(teacher_email), status, created_at desc);
create index if not exists student_report_student_idx2
  on public.student_report_cards (school_code, student_id, published, academic_year desc, term desc);
create index if not exists student_calendar_scope_idx
  on public.student_calendar_events (school_code, active, class_name, section, event_date);

revoke all on table public.student_subject_assignments from public, anon, authenticated;
grant select on table public.student_subject_assignments to authenticated;

drop policy if exists student_subject_assignments_admin_all on public.student_subject_assignments;
drop policy if exists student_subject_assignments_teacher_select on public.student_subject_assignments;
create policy student_subject_assignments_admin_all on public.student_subject_assignments
for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');
create policy student_subject_assignments_teacher_select on public.student_subject_assignments
for select to authenticated
using (school_code='ashiana' and lower(teacher_email)=lower(coalesce((select auth.jwt()->>'email'),'')));

-- Direct authenticated reads of student-facing content are limited to admins
-- and teachers assigned to the corresponding class. Student login uses RPCs.
drop policy if exists student_notices_select on public.student_notices;
create policy student_notices_select on public.student_notices
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_notices.class_name and a.section=student_notices.section
    )
  )
);

drop policy if exists student_homework_select on public.student_homework;
create policy student_homework_select on public.student_homework
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_homework.class_name and a.section=student_homework.section
    )
  )
);

drop policy if exists student_timetable_select on public.student_timetable;
create policy student_timetable_select on public.student_timetable
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_timetable.class_name and a.section=student_timetable.section
    )
  )
);

drop policy if exists student_calendar_select on public.student_calendar_events;
create policy student_calendar_select on public.student_calendar_events
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or class_name is null or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_calendar_events.class_name and a.section=student_calendar_events.section
    )
  )
);

drop policy if exists student_report_select on public.student_report_cards;
create policy student_report_select on public.student_report_cards
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin())
    or lower(published_by)=lower(coalesce((select auth.jwt()->>'email'),''))
    or exists (
      select 1 from public.student_roster s
      join public.student_class_assignments a
        on a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section
       and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
       and a.active
      where s.id=student_report_cards.student_id
    )
  )
);

-- Cache per-request auth helper values inside RLS.
drop policy if exists student_roster_admin_all on public.student_roster;
create policy student_roster_admin_all on public.student_roster
for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');

drop policy if exists student_roster_teacher_select on public.student_roster;
create policy student_roster_teacher_select on public.student_roster
for select to authenticated using (
  exists (
    select 1 from public.student_class_assignments a
    where a.school_code=student_roster.school_code
      and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
      and a.class_name=student_roster.class_name and a.section=student_roster.section and a.active
  )
);

drop policy if exists student_assignments_admin_all on public.student_class_assignments;
create policy student_assignments_admin_all on public.student_class_assignments
for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');

drop policy if exists student_assignments_teacher_select on public.student_class_assignments;
create policy student_assignments_teacher_select on public.student_class_assignments
for select to authenticated using (
  school_code='ashiana' and lower(teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
);

drop policy if exists student_attendance_admin_all on public.student_attendance;
create policy student_attendance_admin_all on public.student_attendance
for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');

drop policy if exists student_attendance_teacher_select on public.student_attendance;
create policy student_attendance_teacher_select on public.student_attendance
for select to authenticated using (
  exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a on a.school_code=s.school_code
      and a.class_name=s.class_name and a.section=s.section
    where s.id=student_attendance.student_id and s.school_code=student_attendance.school_code
      and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
      and a.active
  )
);

drop policy if exists student_attendance_teacher_insert on public.student_attendance;
create policy student_attendance_teacher_insert on public.student_attendance
for insert to authenticated with check (
  (select auth.uid())=marked_by and exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a on a.school_code=s.school_code
      and a.class_name=s.class_name and a.section=s.section
    where s.id=student_attendance.student_id and s.school_code=student_attendance.school_code
      and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
      and a.active
  )
);

drop policy if exists student_attendance_teacher_update on public.student_attendance;
create policy student_attendance_teacher_update on public.student_attendance
for update to authenticated
using (
  exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a on a.school_code=s.school_code
      and a.class_name=s.class_name and a.section=s.section
    where s.id=student_attendance.student_id and s.school_code=student_attendance.school_code
      and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
      and a.active
  )
)
with check (
  (select auth.uid())=marked_by and exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a on a.school_code=s.school_code
      and a.class_name=s.class_name and a.section=s.section
    where s.id=student_attendance.student_id and s.school_code=student_attendance.school_code
      and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
      and a.active
  )
);

drop policy if exists student_leave_student_all on public.student_leave_requests;
create policy student_leave_student_all on public.student_leave_requests
for all to authenticated
using (school_code='ashiana' and ((select private.is_admin()) or lower(teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))))
with check (school_code='ashiana');

drop policy if exists student_leave_teacher_manage on public.student_leave_requests;
create policy student_leave_teacher_manage on public.student_leave_requests
for update to authenticated
using (school_code='ashiana' and ((select private.is_admin()) or lower(teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))))
with check (school_code='ashiana');

revoke execute on function public.student_login(text,text,text) from public, authenticated;
grant execute on function public.student_login(text,text,text) to anon;
revoke execute on function public.student_portal_bundle(text,text) from public, authenticated;
grant execute on function public.student_portal_bundle(text,text) to anon;
revoke execute on function public.student_submit_leave(text,text,date,date,text) from public, authenticated;
grant execute on function public.student_submit_leave(text,text,date,date,text) to anon;
revoke execute on function public.student_portal_data(uuid) from public, anon, authenticated;
