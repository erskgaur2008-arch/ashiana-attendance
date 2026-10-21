-- Student Mentor/Classmates: session-token validated reads.
-- Additive only. Does not modify roster, assignments, attendance, or existing policies.
-- Deploy to EduPunch-Test first; do not apply directly to production.

create or replace function public.student_mentor_list_by_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  s public.student_roster%rowtype;
  v_class_teachers jsonb;
  v_subject_teachers jsonb;
  v_timetable_teachers jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select * into s
    from public.student_roster
   where id = v_student_id
     and school_code = 'ashiana'
     and upper(coalesce(status, '')) = 'ACTIVE';
  if not found or nullif(btrim(s.class_name), '') is null
             or nullif(btrim(s.section), '') is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_CLASS_SECTION_MISSING');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'teacher_email', a.teacher_email, 'role', 'Class Teacher'
  ) order by lower(a.teacher_email)), '[]'::jsonb)
    into v_class_teachers
    from public.student_class_assignments a
   where a.school_code = s.school_code
     and a.class_name = s.class_name
     and a.section = s.section
     and a.active is true
     and nullif(btrim(a.teacher_email), '') is not null;

  select coalesce(jsonb_agg(jsonb_build_object(
    'teacher_email', a.teacher_email,
    'subject_name', a.subject_name,
    'role', 'Subject Teacher'
  ) order by lower(a.teacher_email), a.subject_name), '[]'::jsonb)
    into v_subject_teachers
    from public.student_subject_assignments a
   where a.school_code = s.school_code
     and a.class_name = s.class_name
     and a.section = s.section
     and a.active is true
     and nullif(btrim(a.teacher_email), '') is not null;

  select coalesce(jsonb_agg(jsonb_build_object(
    'teacher_name', t.teacher_name, 'subject_name', t.subject_name
  ) order by t.subject_name, t.teacher_name), '[]'::jsonb)
    into v_timetable_teachers
    from public.student_timetable t
   where t.school_code = s.school_code
     and t.class_name = s.class_name
     and t.section = s.section
     and t.active is true
     and nullif(btrim(t.teacher_name), '') is not null;

  return jsonb_build_object(
    'success', true,
    'class_name', s.class_name,
    'section', s.section,
    'class_teachers', v_class_teachers,
    'subject_teachers', v_subject_teachers,
    'timetable_teachers', v_timetable_teachers
  );
end;
$function$;

revoke all on function public.student_mentor_list_by_session(text) from public, authenticated;
grant execute on function public.student_mentor_list_by_session(text) to anon;

create or replace function public.student_classmates_by_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  s public.student_roster%rowtype;
  v_classmates jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select * into s
    from public.student_roster
   where id = v_student_id
     and school_code = 'ashiana'
     and upper(coalesce(status, '')) = 'ACTIVE';
  if not found or nullif(btrim(s.class_name), '') is null
             or nullif(btrim(s.section), '') is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_CLASS_SECTION_MISSING');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'student_name', r.student_name,
    'roll_no', r.roll_no
  ) order by r.roll_no nulls last, r.student_name), '[]'::jsonb)
    into v_classmates
    from public.student_roster r
   where r.school_code = s.school_code
     and r.class_name = s.class_name
     and r.section = s.section
     and upper(coalesce(r.status, '')) = 'ACTIVE';

  return jsonb_build_object(
    'success', true,
    'class_name', s.class_name,
    'section', s.section,
    'classmates', v_classmates
  );
end;
$function$;

revoke all on function public.student_classmates_by_session(text) from public, authenticated;
grant execute on function public.student_classmates_by_session(text) to anon;
