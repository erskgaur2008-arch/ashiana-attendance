-- Subject Teachers are view-only for student attendance.
-- Only active Class Teachers may insert/update attendance.

drop policy if exists student_attendance_teacher_insert on public.student_attendance;
create policy student_attendance_teacher_insert on public.student_attendance
for insert to authenticated
with check (
  (select auth.uid())=marked_by
  and exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a
      on a.school_code=s.school_code
     and a.class_name=s.class_name
     and a.section=s.section
     and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
     and a.active=true
    where s.id=student_attendance.student_id
      and s.school_code=student_attendance.school_code
  )
);

drop policy if exists student_attendance_teacher_update on public.student_attendance;
create policy student_attendance_teacher_update on public.student_attendance
for update to authenticated
using (
  exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a
      on a.school_code=s.school_code
     and a.class_name=s.class_name
     and a.section=s.section
     and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
     and a.active=true
    where s.id=student_attendance.student_id
      and s.school_code=student_attendance.school_code
  )
)
with check (
  (select auth.uid())=marked_by
  and exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a
      on a.school_code=s.school_code
     and a.class_name=s.class_name
     and a.section=s.section
     and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
     and a.active=true
    where s.id=student_attendance.student_id
      and s.school_code=student_attendance.school_code
  )
);

create or replace function public.mark_student_attendance_by_qr(p_school_code text, p_enroll_no text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email','')));
  v_teacher_name text := '';
  v_enroll text := upper(trim(coalesce(p_enroll_no,'')));
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_student public.student_roster%rowtype;
  v_mark public.student_attendance%rowtype;
  v_exists boolean := false;
begin
  if v_user_id is null or v_email = '' then
    return jsonb_build_object('success',false,'code','AUTH_REQUIRED','message','Teacher authentication is required.');
  end if;
  if lower(trim(coalesce(p_school_code,''))) <> 'ashiana' then
    return jsonb_build_object('success',false,'code','INVALID_SCHOOL','message','Invalid school.');
  end if;
  if v_enroll = '' then
    return jsonb_build_object('success',false,'code','INVALID_QR','message','Student enrollment number is missing.');
  end if;

  if not exists (
    select 1 from public.student_class_assignments a
    where a.school_code='ashiana'
      and lower(trim(a.teacher_email))=v_email
      and a.active=true
  ) then
    return jsonb_build_object('success',false,'code','MARKING_NOT_ALLOWED','message','Only Class Teachers can mark student attendance.');
  end if;

  select coalesce(name,email) into v_teacher_name
  from public.staff
  where lower(trim(email))=v_email and status='ACTIVE'
  limit 1;
  v_teacher_name := coalesce(nullif(trim(v_teacher_name),''),v_email);

  select * into v_student
  from public.student_roster s
  where s.school_code='ashiana'
    and upper(trim(s.enroll_no))=v_enroll
    and s.status='ACTIVE'
  limit 1;

  if not found then
    return jsonb_build_object('success',false,'code','STUDENT_NOT_FOUND','message','Active student was not found for this QR code.');
  end if;

  if not exists (
    select 1 from public.student_class_assignments a
    where a.school_code='ashiana'
      and lower(trim(a.teacher_email))=v_email
      and a.class_name=v_student.class_name
      and a.section=v_student.section
      and a.active=true
  ) then
    return jsonb_build_object('success',false,'code','NOT_ASSIGNED','message','This student is not assigned to your class.','student',
      jsonb_build_object('enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section));
  end if;

  select exists(select 1 from public.student_attendance where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today) into v_exists;

  if v_exists then
    select * into v_mark from public.student_attendance
    where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today limit 1;
    return jsonb_build_object('success',true,'code','ALREADY_MARKED','message','Attendance is already marked for this student today.','status',v_mark.status,'marked_at',v_mark.updated_at,'marked_by_name',coalesce(v_mark.marked_by_name,v_teacher_name),
      'student',jsonb_build_object('id',v_student.id,'enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section,'roll_no',v_student.roll_no));
  end if;

  insert into public.student_attendance(school_code,student_id,attendance_date,status,marked_by,marked_by_name,updated_at)
  values('ashiana',v_student.id,v_today,'PRESENT',v_user_id,v_teacher_name,now())
  returning * into v_mark;

  return jsonb_build_object('success',true,'code','MARKED','message','Student attendance marked present.','status',v_mark.status,'marked_at',v_mark.updated_at,'marked_by_name',v_teacher_name,
    'student',jsonb_build_object('id',v_student.id,'enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section,'roll_no',v_student.roll_no));
exception when unique_violation then
  select * into v_mark from public.student_attendance
  where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today limit 1;
  return jsonb_build_object('success',true,'code','ALREADY_MARKED','message','Attendance was already marked by another scan.','status',coalesce(v_mark.status,'PRESENT'),'marked_at',v_mark.updated_at,'marked_by_name',coalesce(v_mark.marked_by_name,v_teacher_name),
    'student',jsonb_build_object('id',v_student.id,'enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section,'roll_no',v_student.roll_no));
end;
$function$;