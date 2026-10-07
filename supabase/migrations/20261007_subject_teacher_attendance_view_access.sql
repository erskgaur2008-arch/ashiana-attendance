-- Subject Teachers may VIEW attendance for their assigned subject classes.
-- Attendance marking remains restricted to active Class Teachers.

drop policy if exists student_attendance_teacher_select on public.student_attendance;

create policy student_attendance_teacher_select on public.student_attendance
for select to authenticated
using (
  exists (
    select 1
    from public.student_roster s
    join public.student_class_assignments a
      on a.school_code=s.school_code
     and a.class_name=s.class_name
     and a.section=s.section
    where s.id=student_attendance.student_id
      and s.school_code=student_attendance.school_code
      and lower(trim(a.teacher_email))=lower(trim(coalesce((select auth.jwt()->>'email'),'')))
      and a.active=true
  )
  or exists (
    select 1
    from public.student_roster s
    join public.student_subject_assignments sa
      on sa.school_code=s.school_code
     and sa.class_name=s.class_name
     and sa.section=s.section
    where s.id=student_attendance.student_id
      and s.school_code=student_attendance.school_code
      and lower(trim(sa.teacher_email))=lower(trim(coalesce((select auth.jwt()->>'email'),'')))
      and sa.active=true
  )
);
