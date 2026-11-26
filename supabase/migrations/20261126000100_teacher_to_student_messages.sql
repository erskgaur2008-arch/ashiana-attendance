-- Teacher-to-student messages delivered into the existing Student Portal Messages inbox.
-- Every recipient receives a separate private thread; no group thread exposes peers.

create or replace function private.parent_message_teacher_can_target_student(
  p_student_id uuid, p_staff_id text, p_email text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
      from public.student_roster s
     where s.id = p_student_id
       and s.school_code = 'ashiana'
       and upper(coalesce(s.status, '')) = 'ACTIVE'
       and exists (
         select 1 from public.staff me
          where me.id = p_staff_id
            and lower(btrim(me.email)) = lower(btrim(p_email))
            and upper(coalesce(me.status, '')) = 'ACTIVE'
       )
       and (
         exists (
           select 1 from public.student_class_assignments a
            where a.school_code = s.school_code and a.class_name = s.class_name
              and a.section = s.section and a.active is true
              and lower(btrim(a.teacher_email)) = lower(btrim(p_email))
         )
         or exists (
           select 1 from public.student_subject_assignments a
            where a.school_code = s.school_code and a.class_name = s.class_name
              and a.section = s.section and a.active is true
              and lower(btrim(a.teacher_email)) = lower(btrim(p_email))
         )
         or exists (
           select 1 from public.student_timetable tt
            where tt.school_code = s.school_code and tt.class_name = s.class_name
              and tt.section = s.section and tt.active is true
              and lower(btrim(tt.teacher_name)) = lower(btrim((
                select me.name from public.staff me where me.id = p_staff_id
              )))
              and (
                select count(*) from public.staff matched
                 where upper(coalesce(matched.status, '')) = 'ACTIVE'
                   and lower(btrim(matched.name)) = lower(btrim(tt.teacher_name))
              ) = 1
         )
       )
  );
$function$;

revoke all on function private.parent_message_teacher_can_target_student(uuid, text, text) from public, anon, authenticated;

create or replace function public.parent_messages_teacher_targets()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(btrim(coalesce((select auth.jwt() ->> 'email'), '')));
  v_staff_id text;
  v_students jsonb;
begin
  if auth.uid() is null or nullif(v_email, '') is null then
    raise exception 'Teacher sign-in required.' using errcode = '42501';
  end if;

  select st.id into v_staff_id
    from public.staff st
   where lower(btrim(st.email)) = v_email
     and upper(coalesce(st.status, '')) = 'ACTIVE'
   limit 1;
  if v_staff_id is null then
    raise exception 'Active teacher account not found.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'student_id', s.id,
    'student_name', s.student_name,
    'class_name', s.class_name,
    'section', s.section
  ) order by s.class_name, s.section, s.student_name), '[]'::jsonb)
    into v_students
    from public.student_roster s
   where s.school_code = 'ashiana'
     and upper(coalesce(s.status, '')) = 'ACTIVE'
     and private.parent_message_teacher_can_target_student(s.id, v_staff_id, v_email);

  return jsonb_build_object('success', true, 'students', v_students);
end;
$function$;

create or replace function public.parent_messages_teacher_send(
  p_student_ids uuid[], p_subject text, p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(btrim(coalesce((select auth.jwt() ->> 'email'), '')));
  v_staff_id text;
  v_staff_name text;
  v_student_id uuid;
  v_thread_id uuid;
  v_count integer := 0;
  v_unique_count integer;
begin
  if auth.uid() is null or nullif(v_email, '') is null then
    raise exception 'Teacher sign-in required.' using errcode = '42501';
  end if;
  if nullif(btrim(p_subject), '') is null or length(btrim(p_subject)) > 160
     or nullif(btrim(p_body), '') is null or length(btrim(p_body)) > 4000 then
    return jsonb_build_object('success', false, 'code', 'INVALID_MESSAGE');
  end if;
  if p_student_ids is null or cardinality(p_student_ids) = 0
     or cardinality(p_student_ids) > 200 then
    return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENTS');
  end if;

  select st.id, st.name into v_staff_id, v_staff_name
    from public.staff st
   where lower(btrim(st.email)) = v_email
     and upper(coalesce(st.status, '')) = 'ACTIVE'
   limit 1;
  if v_staff_id is null then
    raise exception 'Active teacher account not found.' using errcode = '42501';
  end if;

  select count(distinct requested.student_id)::integer into v_unique_count
    from unnest(p_student_ids) as requested(student_id);
  if v_unique_count <> cardinality(p_student_ids) then
    return jsonb_build_object('success', false, 'code', 'DUPLICATE_RECIPIENTS');
  end if;

  -- Validate the complete recipient set before writing any message.
  if exists (
    select 1 from unnest(p_student_ids) as requested(student_id)
     where not private.parent_message_teacher_can_target_student(requested.student_id, v_staff_id, v_email)
  ) then
    raise exception 'One or more students are outside your active teaching assignments.' using errcode = '42501';
  end if;

  foreach v_student_id in array p_student_ids loop
    insert into public.parent_message_threads (
      student_id, recipient_type, recipient_staff_id, subject,
      last_staff_message_at, staff_last_read_at
    ) values (
      v_student_id, 'TEACHER', v_staff_id, btrim(p_subject), now(), now()
    ) returning id into v_thread_id;

    insert into public.parent_message_messages (
      thread_id, sender_type, sender_name, body
    ) values (
      v_thread_id, 'STAFF', coalesce(nullif(btrim(v_staff_name), ''), 'Teacher'), btrim(p_body)
    );
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('success', true, 'created_count', v_count);
end;
$function$;

revoke all on function public.parent_messages_teacher_targets() from public, anon, authenticated;
revoke all on function public.parent_messages_teacher_send(uuid[], text, text) from public, anon, authenticated;
grant execute on function public.parent_messages_teacher_targets() to authenticated;
grant execute on function public.parent_messages_teacher_send(uuid[], text, text) to authenticated;

notify pgrst, 'reload schema';
