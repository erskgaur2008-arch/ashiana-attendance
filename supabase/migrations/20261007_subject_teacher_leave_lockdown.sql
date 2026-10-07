-- Tighten leave management to the approved role matrix.
-- Students submit through the existing SECURITY DEFINER RPC as anon.
-- Admins retain full authenticated access.
-- Only active Class Teachers can view/update their assigned students' leave requests.
-- Subject Teachers receive no authenticated leave-management access.

drop policy if exists student_leave_student_all on public.student_leave_requests;
drop policy if exists student_leave_teacher_manage on public.student_leave_requests;
drop policy if exists student_leave_admin_all on public.student_leave_requests;
drop policy if exists student_leave_teacher_select on public.student_leave_requests;

create policy student_leave_admin_all on public.student_leave_requests
for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');

create policy student_leave_teacher_select on public.student_leave_requests
for select to authenticated using (
  school_code='ashiana'
  and lower(coalesce(teacher_email,''))=lower(coalesce((select auth.jwt()->>'email'),''))
  and exists (
    select 1
    from public.student_roster s
    join public.student_class_assignments a
      on a.school_code=s.school_code
     and a.class_name=s.class_name
     and a.section=s.section
     and a.active=true
     and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
    where s.id=student_leave_requests.student_id
      and s.school_code=student_leave_requests.school_code
  )
);

create policy student_leave_teacher_manage on public.student_leave_requests
for update to authenticated
using (
  school_code='ashiana'
  and lower(coalesce(teacher_email,''))=lower(coalesce((select auth.jwt()->>'email'),''))
  and exists (
    select 1
    from public.student_roster s
    join public.student_class_assignments a
      on a.school_code=s.school_code
     and a.class_name=s.class_name
     and a.section=s.section
     and a.active=true
     and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
    where s.id=student_leave_requests.student_id
      and s.school_code=student_leave_requests.school_code
  )
)
with check (
  school_code='ashiana'
  and lower(coalesce(teacher_email,''))=lower(coalesce((select auth.jwt()->>'email'),''))
  and exists (
    select 1
    from public.student_roster s
    join public.student_class_assignments a
      on a.school_code=s.school_code
     and a.class_name=s.class_name
     and a.section=s.section
     and a.active=true
     and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
    where s.id=student_leave_requests.student_id
      and s.school_code=student_leave_requests.school_code
  )
);