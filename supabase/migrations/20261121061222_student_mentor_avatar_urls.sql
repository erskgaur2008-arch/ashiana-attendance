create or replace function public.student_mentor_avatars_by_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_student record;
  v_mentors jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select s.school_code, s.class_name, s.section
    into v_student
    from public.student_roster s
   where s.id = v_student_id
     and s.school_code = 'ashiana'
     and upper(coalesce(s.status, '')) = 'ACTIVE';
  if not found or nullif(btrim(v_student.class_name), '') is null
             or nullif(btrim(v_student.section), '') is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_CLASS_SECTION_MISSING');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'teacher_email', st.email,
    'avatar_url', nullif(btrim(st.avatar_url), '')
  ) order by lower(st.email)), '[]'::jsonb)
    into v_mentors
    from (
      select a.teacher_email
        from public.student_class_assignments a
       where a.school_code = v_student.school_code
         and a.class_name = v_student.class_name
         and a.section = v_student.section
         and a.active is true
         and nullif(btrim(a.teacher_email), '') is not null
      union
      select a.teacher_email
        from public.student_subject_assignments a
       where a.school_code = v_student.school_code
         and a.class_name = v_student.class_name
         and a.section = v_student.section
         and a.active is true
         and nullif(btrim(a.teacher_email), '') is not null
    ) assigned
    join public.staff st
      on lower(btrim(st.email)) = lower(btrim(assigned.teacher_email))
     and upper(coalesce(st.status, 'ACTIVE')) = 'ACTIVE'
   where nullif(btrim(st.avatar_url), '') is not null;

  return jsonb_build_object('success', true, 'mentors', v_mentors);
end;
$function$;

revoke all on function public.student_mentor_avatars_by_session(text) from public, authenticated;
grant execute on function public.student_mentor_avatars_by_session(text) to anon;
