-- Two-way family-to-school messaging for the Student Portal and staff portals.
-- Student requests are authorized by the existing revocable student session token.

create table if not exists public.parent_message_threads (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana' check (school_code = 'ashiana'),
  student_id uuid not null references public.student_roster(id) on delete cascade,
  recipient_type text not null check (recipient_type in ('TEACHER', 'PRINCIPAL', 'SCHOOL_ADMINISTRATION')),
  recipient_staff_id text,
  subject text not null check (length(btrim(subject)) between 1 and 160),
  status text not null default 'OPEN' check (status in ('OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  last_parent_message_at timestamptz,
  last_staff_message_at timestamptz,
  parent_last_read_at timestamptz,
  staff_last_read_at timestamptz,
  constraint parent_message_teacher_recipient_check check (
    (recipient_type = 'TEACHER' and recipient_staff_id is not null)
    or (recipient_type <> 'TEACHER' and recipient_staff_id is null)
  )
);

create table if not exists public.parent_message_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.parent_message_threads(id) on delete cascade,
  sender_type text not null check (sender_type in ('PARENT_GUARDIAN', 'STAFF', 'ADMIN')),
  sender_name text not null check (length(btrim(sender_name)) between 1 and 120),
  body text not null check (length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now()
);

create index if not exists parent_message_threads_student_recent_idx
  on public.parent_message_threads(student_id, last_message_at desc);
create index if not exists parent_message_threads_teacher_recent_idx
  on public.parent_message_threads(recipient_staff_id, last_message_at desc)
  where recipient_type = 'TEACHER';
create index if not exists parent_message_messages_thread_idx
  on public.parent_message_messages(thread_id, created_at);

alter table public.parent_message_threads enable row level security;
alter table public.parent_message_messages enable row level security;
revoke all on public.parent_message_threads, public.parent_message_messages from public, anon, authenticated;

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
        on lower(me.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
       and upper(coalesce(me.status, '')) = 'ACTIVE'
     where t.id = p_thread_id
       and s.school_code = 'ashiana'
       and upper(coalesce(s.status, '')) = 'ACTIVE'
       and case t.recipient_type
         when 'TEACHER' then me.id = t.recipient_staff_id and (
           exists (
             select 1 from public.student_class_assignments a
              where a.school_code = s.school_code and a.class_name = s.class_name
                and a.section = s.section and a.active
                and lower(a.teacher_email) = lower(me.email)
           ) or exists (
             select 1 from public.student_subject_assignments a
              where a.school_code = s.school_code and a.class_name = s.class_name
                and a.section = s.section and a.active
                and lower(a.teacher_email) = lower(me.email)
           )
         )
         when 'PRINCIPAL' then lower(btrim(me.role)) in ('principal', 'vice principal')
         when 'SCHOOL_ADMINISTRATION' then lower(btrim(me.role)) = 'admin'
         else false
       end
  )
$function$;

revoke all on function private.parent_message_staff_can_access_thread(uuid) from public, anon, authenticated;

create or replace function private.parent_message_block_closed_thread()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if exists (
    select 1 from public.parent_message_threads t
     where t.id = new.thread_id and t.status = 'CLOSED'
  ) then
    raise exception 'This conversation is closed.' using errcode = '55000';
  end if;
  return new;
end;
$function$;

revoke all on function private.parent_message_block_closed_thread() from public, anon, authenticated;
drop trigger if exists trg_parent_message_block_closed_thread on public.parent_message_messages;
create trigger trg_parent_message_block_closed_thread
before insert on public.parent_message_messages
for each row execute function private.parent_message_block_closed_thread();

create or replace function private.parent_message_touch_thread()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update public.parent_message_threads t
     set updated_at = now(),
         last_message_at = new.created_at,
         last_parent_message_at = case when new.sender_type = 'PARENT_GUARDIAN' then new.created_at else t.last_parent_message_at end,
         last_staff_message_at = case when new.sender_type <> 'PARENT_GUARDIAN' then new.created_at else t.last_staff_message_at end,
         status = case
           when new.sender_type = 'PARENT_GUARDIAN' then 'OPEN'
           when t.status = 'OPEN' then 'IN_PROGRESS'
           else t.status
         end
   where t.id = new.thread_id;
  return new;
end;
$function$;

revoke all on function private.parent_message_touch_thread() from public, anon, authenticated;
drop trigger if exists trg_parent_message_touch_thread on public.parent_message_messages;
create trigger trg_parent_message_touch_thread
after insert on public.parent_message_messages
for each row execute function private.parent_message_touch_thread();

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
             and a.section = v_student.section and a.active
             and lower(a.teacher_email) = lower(st.email)
        ) then 'Class Teacher' else 'Subject Teacher' end as role_label
        from public.staff st
       where upper(coalesce(st.status, '')) = 'ACTIVE'
         and (
           exists (
             select 1 from public.student_class_assignments a
              where a.school_code = v_student.school_code and a.class_name = v_student.class_name
                and a.section = v_student.section and a.active
                and lower(a.teacher_email) = lower(st.email)
           ) or exists (
             select 1 from public.student_subject_assignments a
              where a.school_code = v_student.school_code and a.class_name = v_student.class_name
                and a.section = v_student.section and a.active
                and lower(a.teacher_email) = lower(st.email)
           )
         )
       group by st.id, st.name, st.email
    ) x;

  return jsonb_build_object('success', true, 'teachers', v_teachers);
end;
$function$;

create or replace function public.parent_messages_student_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_threads jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'subject', t.subject, 'recipient_type', t.recipient_type,
    'recipient_name', case t.recipient_type
      when 'TEACHER' then coalesce(st.name, 'Teacher')
      when 'PRINCIPAL' then 'Principal / Vice Principal'
      else 'School Administration'
    end,
    'status', t.status, 'last_message_at', t.last_message_at,
    'unread', t.last_staff_message_at is not null
      and t.last_staff_message_at > coalesce(t.parent_last_read_at, '-infinity'::timestamptz)
  ) order by t.last_message_at desc), '[]'::jsonb)
    into v_threads
    from public.parent_message_threads t
    left join public.staff st on st.id = t.recipient_staff_id
   where t.student_id = v_student_id and t.school_code = 'ashiana';

  update public.parent_message_threads
     set parent_last_read_at = now()
   where student_id = v_student_id and school_code = 'ashiana';

  return jsonb_build_object('success', true, 'threads', v_threads);
end;
$function$;

create or replace function public.parent_messages_student_thread(p_token text, p_thread_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_thread public.parent_message_threads%rowtype;
  v_messages jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select * into v_thread from public.parent_message_threads t
   where t.id = p_thread_id and t.student_id = v_student_id and t.school_code = 'ashiana';
  if not found then
    return jsonb_build_object('success', false, 'code', 'THREAD_NOT_FOUND');
  end if;

  update public.parent_message_threads set parent_last_read_at = now() where id = p_thread_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'sender_type', m.sender_type, 'sender_name', m.sender_name,
    'body', m.body, 'created_at', m.created_at
  ) order by m.created_at), '[]'::jsonb)
    into v_messages from public.parent_message_messages m where m.thread_id = p_thread_id;

  return jsonb_build_object(
    'success', true, 'thread', jsonb_build_object(
      'id', v_thread.id, 'subject', v_thread.subject, 'recipient_type', v_thread.recipient_type,
      'recipient_name', case v_thread.recipient_type
        when 'TEACHER' then coalesce((select st.name from public.staff st where st.id = v_thread.recipient_staff_id), 'Teacher')
        when 'PRINCIPAL' then 'Principal / Vice Principal'
        else 'School Administration'
      end,
      'status', v_thread.status, 'created_at', v_thread.created_at
    ), 'messages', v_messages
  );
end;
$function$;

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
             and a.section = v_student.section and a.active and lower(a.teacher_email) = lower(st.email))
         or exists (select 1 from public.student_subject_assignments a
           where a.school_code = v_student.school_code and a.class_name = v_student.class_name
             and a.section = v_student.section and a.active and lower(a.teacher_email) = lower(st.email))
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

create or replace function public.parent_messages_student_reply(p_token text, p_thread_id uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_student_name text;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;
  if nullif(btrim(p_body), '') is null or length(btrim(p_body)) > 4000 then
    return jsonb_build_object('success', false, 'code', 'INVALID_MESSAGE');
  end if;

  select s.student_name into v_student_name
    from public.parent_message_threads t
    join public.student_roster s on s.id = t.student_id
   where t.id = p_thread_id and t.student_id = v_student_id
     and t.school_code = 'ashiana' and t.status <> 'CLOSED'
     and upper(coalesce(s.status, '')) = 'ACTIVE';
  if not found then
    return jsonb_build_object('success', false, 'code', 'THREAD_NOT_FOUND_OR_CLOSED');
  end if;

  insert into public.parent_message_messages (thread_id, sender_type, sender_name, body)
  values (p_thread_id, 'PARENT_GUARDIAN', 'Family of ' || v_student_name, btrim(p_body));
  return jsonb_build_object('success', true, 'thread_id', p_thread_id);
end;
$function$;

create or replace function public.parent_messages_staff_list()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(coalesce((select auth.jwt() ->> 'email'), ''));
  v_threads jsonb;
begin
  if auth.uid() is null or (
    not coalesce((select private.is_admin()), false)
    and not exists (select 1 from public.staff st where lower(st.email) = v_email and upper(coalesce(st.status, '')) = 'ACTIVE')
  ) then
    raise exception 'School staff access required.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'subject', t.subject, 'recipient_type', t.recipient_type,
    'recipient_name', case t.recipient_type
      when 'TEACHER' then coalesce(recipient.name, 'Teacher')
      when 'PRINCIPAL' then 'Principal / Vice Principal'
      else 'School Administration'
    end,
    'student_name', s.student_name, 'class_name', s.class_name, 'section', s.section,
    'status', t.status, 'last_message_at', t.last_message_at,
    'unread', t.last_parent_message_at is not null
      and t.last_parent_message_at > coalesce(t.staff_last_read_at, '-infinity'::timestamptz)
  ) order by t.last_message_at desc), '[]'::jsonb)
    into v_threads
    from public.parent_message_threads t
    join public.student_roster s on s.id = t.student_id
    left join public.staff recipient on recipient.id = t.recipient_staff_id
   where t.school_code = 'ashiana'
     and private.parent_message_staff_can_access_thread(t.id);

  update public.parent_message_threads t set staff_last_read_at = now()
   where t.school_code = 'ashiana'
     and private.parent_message_staff_can_access_thread(t.id);

  return jsonb_build_object('success', true, 'threads', v_threads);
end;
$function$;

create or replace function public.parent_messages_staff_thread(p_thread_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(coalesce((select auth.jwt() ->> 'email'), ''));
  v_thread public.parent_message_threads%rowtype;
  v_student public.student_roster%rowtype;
  v_messages jsonb;
begin
  if auth.uid() is null or (
    not coalesce((select private.is_admin()), false)
    and not exists (select 1 from public.staff st where lower(st.email) = v_email and upper(coalesce(st.status, '')) = 'ACTIVE')
  ) then
    raise exception 'School staff access required.' using errcode = '42501';
  end if;
  if not private.parent_message_staff_can_access_thread(p_thread_id) then
    raise exception 'You cannot access this family conversation.' using errcode = '42501';
  end if;

  select * into v_thread from public.parent_message_threads t where t.id = p_thread_id;
  select * into v_student from public.student_roster s where s.id = v_thread.student_id;
  update public.parent_message_threads set staff_last_read_at = now() where id = p_thread_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'sender_type', m.sender_type, 'sender_name', m.sender_name,
    'body', m.body, 'created_at', m.created_at
  ) order by m.created_at), '[]'::jsonb)
    into v_messages from public.parent_message_messages m where m.thread_id = p_thread_id;

  return jsonb_build_object(
    'success', true,
    'thread', jsonb_build_object(
      'id', v_thread.id, 'subject', v_thread.subject, 'recipient_type', v_thread.recipient_type,
      'recipient_name', case v_thread.recipient_type
        when 'TEACHER' then coalesce((select st.name from public.staff st where st.id = v_thread.recipient_staff_id), 'Teacher')
        when 'PRINCIPAL' then 'Principal / Vice Principal'
        else 'School Administration'
      end,
      'student_name', v_student.student_name, 'class_name', v_student.class_name,
      'section', v_student.section, 'status', v_thread.status,
      'created_at', v_thread.created_at
    ), 'messages', v_messages
  );
end;
$function$;

create or replace function public.parent_messages_staff_reply(p_thread_id uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(coalesce((select auth.jwt() ->> 'email'), ''));
  v_name text;
  v_sender_type text;
begin
  if auth.uid() is null or nullif(v_email, '') is null or (
    not coalesce((select private.is_admin()), false)
    and not exists (select 1 from public.staff st where lower(st.email) = v_email and upper(coalesce(st.status, '')) = 'ACTIVE')
  ) then
    raise exception 'School staff access required.' using errcode = '42501';
  end if;
  if nullif(btrim(p_body), '') is null or length(btrim(p_body)) > 4000 then
    return jsonb_build_object('success', false, 'code', 'INVALID_MESSAGE');
  end if;
  if not private.parent_message_staff_can_access_thread(p_thread_id) then
    raise exception 'You cannot reply to this family conversation.' using errcode = '42501';
  end if;
  if exists (select 1 from public.parent_message_threads t where t.id = p_thread_id and t.status = 'CLOSED') then
    return jsonb_build_object('success', false, 'code', 'THREAD_CLOSED');
  end if;

  if coalesce((select private.is_admin()), false) then
    v_sender_type := 'ADMIN';
    v_name := 'School Administration';
  else
    v_sender_type := 'STAFF';
    select st.name into v_name from public.staff st
     where lower(st.email) = v_email and upper(coalesce(st.status, '')) = 'ACTIVE'
     limit 1;
  end if;

  insert into public.parent_message_messages (thread_id, sender_type, sender_name, body)
  values (p_thread_id, v_sender_type, coalesce(nullif(btrim(v_name), ''), 'School Staff'), btrim(p_body));
  return jsonb_build_object('success', true, 'thread_id', p_thread_id);
end;
$function$;

create or replace function public.parent_messages_staff_set_status(p_thread_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(coalesce((select auth.jwt() ->> 'email'), ''));
begin
  if auth.uid() is null or (
    not coalesce((select private.is_admin()), false)
    and not exists (select 1 from public.staff st where lower(st.email) = v_email and upper(coalesce(st.status, '')) = 'ACTIVE')
  ) then
    raise exception 'School staff access required.' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED') then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATUS');
  end if;
  if not private.parent_message_staff_can_access_thread(p_thread_id) then
    raise exception 'You cannot update this family conversation.' using errcode = '42501';
  end if;

  update public.parent_message_threads set status = p_status, updated_at = now()
   where id = p_thread_id and school_code = 'ashiana';
  if not found then
    return jsonb_build_object('success', false, 'code', 'THREAD_NOT_FOUND');
  end if;
  return jsonb_build_object('success', true, 'thread_id', p_thread_id, 'status', p_status);
end;
$function$;

revoke all on function public.parent_messages_student_targets(text) from public, anon, authenticated;
revoke all on function public.parent_messages_student_list(text) from public, anon, authenticated;
revoke all on function public.parent_messages_student_thread(text, uuid) from public, anon, authenticated;
revoke all on function public.parent_messages_student_create(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.parent_messages_student_reply(text, uuid, text) from public, anon, authenticated;
revoke all on function public.parent_messages_staff_list() from public, anon, authenticated;
revoke all on function public.parent_messages_staff_thread(uuid) from public, anon, authenticated;
revoke all on function public.parent_messages_staff_reply(uuid, text) from public, anon, authenticated;
revoke all on function public.parent_messages_staff_set_status(uuid, text) from public, anon, authenticated;

grant execute on function public.parent_messages_student_targets(text) to anon;
grant execute on function public.parent_messages_student_list(text) to anon;
grant execute on function public.parent_messages_student_thread(text, uuid) to anon;
grant execute on function public.parent_messages_student_create(text, text, text, text, text) to anon;
grant execute on function public.parent_messages_student_reply(text, uuid, text) to anon;
grant execute on function public.parent_messages_staff_list() to authenticated;
grant execute on function public.parent_messages_staff_thread(uuid) to authenticated;
grant execute on function public.parent_messages_staff_reply(uuid, text) to authenticated;
grant execute on function public.parent_messages_staff_set_status(uuid, text) to authenticated;

alter table public.role_portal_module_permissions
  drop constraint if exists role_portal_module_permissions_module_key_check;
alter table public.role_portal_module_permissions
  add constraint role_portal_module_permissions_module_key_check
  check (module_key in (
    'punch', 'history', 'students', 'communication', 'leave', 'profile', 'biometric',
    'mentor', 'classmates', 'notice', 'attendance', 'report-card', 'fees', 'homework',
    'timetable', 'calendar', 'id-card', 'event-photos', 'messages'
  ));
insert into public.role_portal_module_permissions (role, module_key, enabled)
values ('STUDENT', 'messages', true)
on conflict (role, module_key) do nothing;

notify pgrst, 'reload schema';
