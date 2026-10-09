-- Approved leave must be reflected in attendance and cannot be overwritten by QR punches.
-- Apply through the reviewed migration workflow; this file does not execute against production.

create or replace function public.sync_approved_student_leave_attendance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.status = 'APPROVED' then
    insert into public.student_attendance (
      school_code, student_id, attendance_date, status, marked_by, marked_by_name, updated_at
    )
    select new.school_code, new.student_id, d::date, 'LEAVE', null, 'Approved Leave', now()
    from generate_series(new.from_date, new.to_date, interval '1 day') as d
    on conflict (school_code, student_id, attendance_date)
    do update set
      status = 'LEAVE',
      marked_by = null,
      marked_by_name = 'Approved Leave',
      updated_at = now();
  end if;
  return new;
end;
$function$;

drop trigger if exists sync_approved_student_leave_attendance on public.student_leave_requests;
create trigger sync_approved_student_leave_attendance
after insert or update of status, from_date, to_date
on public.student_leave_requests
for each row
when (new.status = 'APPROVED')
execute function public.sync_approved_student_leave_attendance();

-- Backfill attendance for already-approved student leave requests.
insert into public.student_attendance (
  school_code, student_id, attendance_date, status, marked_by, marked_by_name, updated_at
)
select l.school_code, l.student_id, d::date, 'LEAVE', null, 'Approved Leave', now()
from public.student_leave_requests l
cross join lateral generate_series(l.from_date, l.to_date, interval '1 day') as d
where l.school_code = 'ashiana'
  and l.status = 'APPROVED'
on conflict (school_code, student_id, attendance_date)
do update set
  status = 'LEAVE',
  marked_by = null,
  marked_by_name = 'Approved Leave',
  updated_at = now();

-- Defense in depth: QR attendance checks the approved leave window before inserting PRESENT.
create or replace function public.mark_student_attendance_by_qr(p_school_code text, p_enroll_no text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email','')));
  v_teacher_name text := '';
  v_enroll text := upper(trim(coalesce(p_enroll_no,'')));
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_student public.student_roster%rowtype;
  v_mark public.student_attendance%rowtype;
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

  -- Synchronize the current day defensively in case a leave was approved before this migration.
  if exists (
    select 1 from public.student_leave_requests l
    where l.school_code='ashiana' and l.student_id=v_student.id and l.status='APPROVED'
      and v_today between l.from_date and l.to_date
  ) then
    insert into public.student_attendance(school_code,student_id,attendance_date,status,marked_by,marked_by_name,updated_at)
    values('ashiana',v_student.id,v_today,'LEAVE',null,'Approved Leave',now())
    on conflict (school_code,student_id,attendance_date)
    do update set status='LEAVE',marked_by=null,marked_by_name='Approved Leave',updated_at=now();
    select * into v_mark from public.student_attendance
    where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today;
    return jsonb_build_object('success',true,'code','LEAVE_APPROVED','message','Leave is approved for today. Attendance remains marked as LEAVE.','status','LEAVE','marked_at',v_mark.updated_at,
      'student',jsonb_build_object('id',v_student.id,'enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section,'roll_no',v_student.roll_no));
  end if;

  select * into v_mark from public.student_attendance
  where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today;
  if found then
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
  where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today;
  return jsonb_build_object('success',true,'code','ALREADY_MARKED','message','Attendance was already marked by another scan.','status',coalesce(v_mark.status,'PRESENT'),'marked_at',v_mark.updated_at,'marked_by_name',coalesce(v_mark.marked_by_name,v_teacher_name),
    'student',jsonb_build_object('id',v_student.id,'enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section,'roll_no',v_student.roll_no));
end;
$function$;

-- Staff QR/PIN punches are rejected on dates covered by an approved staff leave request.
create or replace function public.record_attendance_punch_service(
  p_staff_id text,
  p_attendance_date date,
  p_type text,
  p_timestamp text,
  p_method text default 'QR_PIN'
)
returns public.attendance_punches
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v public.attendance_punches;
  v_staff public.staff;
  v_latest public.attendance_punches;
  v_expected text;
begin
  if p_attendance_date is null then raise exception 'Attendance date required'; end if;
  if p_type not in ('IN','OUT') then raise exception 'Invalid punch type'; end if;

  select * into v_staff from public.staff where id=p_staff_id and status='ACTIVE' for update;
  if not found then raise exception 'Active staff record not found'; end if;

  if exists (
    select 1 from public.leave_requests l
    where l.staff_id::text=p_staff_id and l.status='APPROVED'
      and p_attendance_date between l.from_date and l.to_date
  ) then
    raise exception 'STAFF_ON_APPROVED_LEAVE';
  end if;

  select * into v_latest from public.attendance_punches
  where staff_id=p_staff_id and attendance_date=p_attendance_date
  order by created_at desc limit 1;

  if v_latest.id is not null and v_latest.created_at > now() - interval '30 seconds' then
    raise exception 'DUPLICATE_SCAN_WAIT_30_SECONDS';
  end if;
  v_expected := case when v_latest.id is null or v_latest.type='OUT' then 'IN' else 'OUT' end;
  if p_type <> v_expected then raise exception 'PUNCH_SEQUENCE_CONFLICT'; end if;

  insert into public.attendance_punches(id,staff_id,staff_name,emp_id,attendance_date,type,timestamp,method)
  values(extensions.gen_random_uuid()::text,v_staff.id,v_staff.name,v_staff.emp_id,p_attendance_date,p_type,p_timestamp,coalesce(nullif(p_method,''),'QR_PIN'))
  returning * into v;
  return v;
end;
$function$;

revoke execute on function public.record_attendance_punch_service(text,date,text,text,text) from public, anon, authenticated;
grant execute on function public.record_attendance_punch_service(text,date,text,text,text) to service_role;

notify pgrst, 'reload schema';
