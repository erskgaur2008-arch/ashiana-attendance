-- Teacher attendance view-only access across all active classes.
-- Class Teachers retain write access only to their assigned class/section.
-- Non-Class Teachers can view attendance but cannot insert/update it.

create or replace function public.teacher_attendance_classes()
returns table(class_name text, section text)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email','')));
  v_role text := '';
begin
  if auth.uid() is null or v_email = '' then raise exception 'AUTH_REQUIRED'; end if;
  select lower(trim(coalesce(s.role,''))) into v_role from public.staff s
  where lower(trim(coalesce(s.email,''))) = v_email and s.status = 'ACTIVE' limit 1;
  if v_role !~* '(^|[^a-z])(teacher|tgt|pgt|prt|pet|special educator|pre-primary teacher)([^a-z]|$)' then raise exception 'NOT_AUTHORIZED'; end if;
  return query select distinct s.class_name, s.section from public.student_roster s
  where s.school_code='ashiana' and s.status='ACTIVE' order by s.class_name, s.section;
end;
$function$;

create or replace function public.teacher_view_student_attendance(
  p_class_name text,
  p_section text,
  p_attendance_date date default ((now() at time zone 'Asia/Kolkata')::date)
)
returns table(
  id uuid, enroll_no text, student_name text, class_name text, section text, roll_no text,
  gender text, category text, status text, attendance_status text, marked_by uuid,
  marked_by_name text, attendance_updated_at timestamptz
)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email','')));
  v_role text := '';
  v_class text := trim(coalesce(p_class_name,''));
  v_section text := trim(coalesce(p_section,''));
begin
  if auth.uid() is null or v_email = '' then raise exception 'AUTH_REQUIRED'; end if;
  select lower(trim(coalesce(s.role,''))) into v_role from public.staff s
  where lower(trim(coalesce(s.email,''))) = v_email and s.status = 'ACTIVE' limit 1;
  if v_role !~* '(^|[^a-z])(teacher|tgt|pgt|prt|pet|special educator|pre-primary teacher)([^a-z]|$)' then raise exception 'NOT_AUTHORIZED'; end if;
  if v_class = '' or v_section = '' then raise exception 'INVALID_CLASS'; end if;
  return query
  select s.id,s.enroll_no,s.student_name,s.class_name,s.section,s.roll_no,s.gender,s.category,s.status,
    a.status,a.marked_by,a.marked_by_name,a.updated_at
  from public.student_roster s
  left join public.student_attendance a
    on a.school_code=s.school_code and a.student_id=s.id
   and a.attendance_date=coalesce(p_attendance_date,(now() at time zone 'Asia/Kolkata')::date)
  where s.school_code='ashiana' and s.status='ACTIVE' and s.class_name=v_class and s.section=v_section
  order by s.roll_no,s.student_name;
end;
$function$;

revoke all on function public.teacher_attendance_classes() from public, anon, authenticated;
revoke all on function public.teacher_view_student_attendance(text,text,date) from public, anon, authenticated;
grant execute on function public.teacher_attendance_classes() to authenticated;
grant execute on function public.teacher_view_student_attendance(text,text,date) to authenticated;
