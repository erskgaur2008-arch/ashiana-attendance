-- Include active timetable teachers in family messaging recipients.
-- Timetable assignments store a teacher name rather than an email, so only
-- match a unique active staff name to avoid routing a thread ambiguously.

create or replace function private.parent_message_staff_can_access_thread(p_thread_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce((select private.is_admin()), false) or exists (
    select 1
      from public.parent_message_threads t
      join public.student_roster s on s.id = t.student_id
      join public.staff me
        on lower(btrim(me.email)) = lower(btrim(coalesce((select auth.jwt() ->> 'email'), '')))
       and upper(coalesce(me.status, '')) = 'ACTIVE'
     where t.id = p_thread_id
       and s.school_code = 'ashiana'
       and upper(coalesce(s.status, '')) = 'ACTIVE'
       and case t.recipient_type
         when 'TEACHER' then me.id = t.recipient_staff_id and (
           exists (
             select 1 from public.student_class_assignments a
              where a.school_code = s.school_code and a.class_name = s.class_name
                and a.section = s.section and a.active is true
                and lower(btrim(a.teacher_email)) = lower(btrim(me.email))
           ) or exists (
             select 1 from public.student_subject_assignments a
              where a.school_code = s.school_code and a.class_name = s.class_name
                and a.section = s.section and a.active is true
                and lower(btrim(a.teacher_email)) = lower(btrim(me.email))
           ) or exists (
             select 1 from public.student_timetable tt
              where tt.school_code = s.school_code and tt.class_name = s.class_name
                and tt.section = s.section and tt.active is true
                and lower(btrim(tt.teacher_name)) = lower(btrim(me.name))
                and (
                  select count(*) from public.staff matched
                   where upper(coalesce(matched.status, '')) = 'ACTIVE'
                     and lower(btrim(matched.name)) = lower(btrim(tt.teacher_name))
                ) = 1
           )
         )
         when 'PRINCIPAL' then lower(btrim(me.role)) in ('principal', 'vice principal')
         when 'SCHOOL_ADMINISTRATION' then lower(btrim(me.role)) = 'admin'
         else false
       end
  )
$function$;

revoke all on function private.parent_message_staff_can_access_thread(uuid) from public, anon, authenticated;

create or replace function public.parent_messages_student_targets(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_student public.student_roster%rowtype;
  v_teachers jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select * into v_student
    from public.student_roster s
   where s.id = v_student_id and s.school_code = 'ashiana'
     and upper(coalesce(s.status, '')) = 'ACTIVE';
  if not found then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id', x.id,
    'name', x.name,
    'role', x.role_label
  ) order by x.name), '[]'::jsonb)
    into v_teachers
    from (
      select st.id, st.name,
        case when exists (
          select 1 from public.student_class_assignments a
           where a.school_code = v_student.school_code and a.class_name = v_student.class_name
             and a.section = v_student.section and a.active is true
             and lower(btrim(a.teacher_email)) = lower(btrim(st.email))
        ) then 'Class Teacher' else 'Subject Teacher' end as role_label
        from public.staff st
       where upper(coalesce(st.status, '')) = 'ACTIVE'
         and (
           exists (
             select 1 from public.student_class_assignments a
              where a.school_code = v_student.school_code and a.class_name = v_student.class_name
                and a.section = v_student.section and a.active is true
                and lower(btrim(a.teacher_email)) = lower(btrim(st.email))
           ) or exists (
             select 1 from public.student_subject_assignments a
              where a.school_code = v_student.school_code and a.class_name = v_student.class_name
                and a.section = v_student.section and a.active is true
                and lower(btrim(a.teacher_email)) = lower(btrim(st.email))
           ) or exists (
             select 1 from public.student_timetable tt
              where tt.school_code = v_student.school_code and tt.class_name = v_student.class_name
                and tt.section = v_student.section and tt.active is true
                and lower(btrim(tt.teacher_name)) = lower(btrim(st.name))
                and (
                  select count(*) from public.staff matched
                   where upper(coalesce(matched.status, '')) = 'ACTIVE'
                     and lower(btrim(matched.name)) = lower(btrim(tt.teacher_name))
                ) = 1
           )
         )
    ) x;

  return jsonb_build_object('success', true, 'teachers', v_teachers);
end;
$function$;

revoke all on function public.parent_messages_student_targets(text) from public, anon, authenticated;
grant execute on function public.parent_messages_student_targets(text) to anon;

create or replace function public.parent_messages_student_create(
  p_token text, p_recipient_type text, p_recipient_staff_id text, p_subject text, p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_student public.student_roster%rowtype;
  v_thread_id uuid;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  if p_recipient_type is null or p_recipient_type not in ('TEACHER', 'PRINCIPAL', 'SCHOOL_ADMINISTRATION')
     or nullif(btrim(p_subject), '') is null or length(btrim(p_subject)) > 160
     or nullif(btrim(p_body), '') is null or length(btrim(p_body)) > 4000 then
    return jsonb_build_object('success', false, 'code', 'INVALID_MESSAGE');
  end if;
  if (p_recipient_type = 'TEACHER' and nullif(btrim(p_recipient_staff_id), '') is null)
     or (p_recipient_type <> 'TEACHER' and p_recipient_staff_id is not null) then
    return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT');
  end if;

  select * into v_student from public.student_roster s
   where s.id = v_student_id and s.school_code = 'ashiana'
     and upper(coalesce(s.status, '')) = 'ACTIVE';
  if not found then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  if p_recipient_type = 'TEACHER' and not exists (
    select 1 from public.staff st
     where st.id = p_recipient_staff_id and upper(coalesce(st.status, '')) = 'ACTIVE'
       and (
         exists (select 1 from public.student_class_assignments a
           where a.school_code = v_student.school_code and a.class_name = v_student.class_name
             and a.section = v_student.section and a.active is true
             and lower(btrim(a.teacher_email)) = lower(btrim(st.email)))
         or exists (select 1 from public.student_subject_assignments a
           where a.school_code = v_student.school_code and a.class_name = v_student.class_name
             and a.section = v_student.section and a.active is true
             and lower(btrim(a.teacher_email)) = lower(btrim(st.email)))
         or exists (select 1 from public.student_timetable tt
           where tt.school_code = v_student.school_code and tt.class_name = v_student.class_name
             and tt.section = v_student.section and tt.active is true
             and lower(btrim(tt.teacher_name)) = lower(btrim(st.name))
             and (select count(*) from public.staff matched
               where upper(coalesce(matched.status, '')) = 'ACTIVE'
                 and lower(btrim(matched.name)) = lower(btrim(tt.teacher_name))) = 1)
       )
  ) then
    return jsonb_build_object('success', false, 'code', 'TEACHER_NOT_ASSIGNED');
  end if;

  if p_recipient_type = 'PRINCIPAL' and not exists (
    select 1 from public.staff st where upper(coalesce(st.status, '')) = 'ACTIVE'
      and lower(btrim(st.role)) in ('principal', 'vice principal')
  ) then
    return jsonb_build_object('success', false, 'code', 'PRINCIPAL_NOT_AVAILABLE');
  end if;
  if p_recipient_type = 'SCHOOL_ADMINISTRATION'
     and not (exists (select 1 from public.admin_users a where a.active)
       or exists (select 1 from public.staff st where upper(coalesce(st.status, '')) = 'ACTIVE' and lower(btrim(st.role)) = 'admin')) then
    return jsonb_build_object('success', false, 'code', 'ADMINISTRATION_NOT_AVAILABLE');
  end if;

  insert into public.parent_message_threads (
    student_id, recipient_type, recipient_staff_id, subject,
    last_parent_message_at, parent_last_read_at
  ) values (
    v_student_id, p_recipient_type,
    case when p_recipient_type = 'TEACHER' then p_recipient_staff_id else null end,
    btrim(p_subject), now(), now()
  ) returning id into v_thread_id;

  insert into public.parent_message_messages (thread_id, sender_type, sender_name, body)
  values (
    v_thread_id, 'PARENT_GUARDIAN', 'Family of ' || v_student.student_name, btrim(p_body)
  );

  return jsonb_build_object('success', true, 'thread_id', v_thread_id);
end;
$function$;

revoke all on function public.parent_messages_student_create(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.parent_messages_student_create(text, text, text, text, text) to anon;

notify pgrst, 'reload schema';
