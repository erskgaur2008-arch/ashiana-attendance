-- Student attendance notifications: additive and isolated from attendance records.
-- Notifications are created only after the attendance write succeeds. No production
-- data is changed by adding this migration; review and test before applying anywhere.

create table if not exists public.student_attendance_notifications (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  student_id uuid not null references public.student_roster(id) on delete cascade,
  attendance_date date not null,
  status text not null check (status in ('PRESENT','ABSENT','LEAVE')),
  title text not null,
  message text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint student_attendance_notifications_once_per_status
    unique (student_id, attendance_date, status)
);

create index if not exists student_attendance_notifications_student_recent_idx
  on public.student_attendance_notifications(student_id, created_at desc);

alter table public.student_attendance_notifications enable row level security;
revoke all on table public.student_attendance_notifications from public, anon, authenticated;

-- Extend the existing secure-session bundle. All existing bundle fields and leave
-- behavior are preserved; only the signed-in student's notification list is added.
create or replace function public.student_portal_bundle_by_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  s public.student_roster%rowtype;
  v_dob_password text;
  v_bundle jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select * into s
    from public.student_roster
   where id = v_student_id
     and school_code = 'ashiana'
     and lower(coalesce(status, '')) = 'active';
  if not found then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  v_dob_password := to_char(s.dob, 'DDMMYYYY');
  v_bundle := public.student_portal_bundle(s.enroll_no, v_dob_password);
  if coalesce((v_bundle->>'success')::boolean, false) is not true then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  if to_regprocedure('public.student_submit_leave(text,text,date,date,text)') is null then
    v_bundle := jsonb_set(v_bundle, '{leave_requests}', coalesce((
      select jsonb_agg(to_jsonb(l) order by l.created_at desc)
      from public.student_leave_requests l
      where l.student_id = s.id and l.school_code = 'ashiana'
    ), '[]'::jsonb), true);
  end if;

  v_bundle := jsonb_set(v_bundle, '{attendance_notifications}', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id,
      'attendance_date', n.attendance_date,
      'status', n.status,
      'title', n.title,
      'message', n.message,
      'created_at', n.created_at,
      'read_at', n.read_at
    ) order by n.created_at desc)
    from public.student_attendance_notifications n
    where n.student_id = s.id and n.school_code = 'ashiana'
  ), '[]'::jsonb), true);

  return v_bundle;
end;
$function$;

revoke all on function public.student_portal_bundle_by_session(text) from public, authenticated;
grant execute on function public.student_portal_bundle_by_session(text) to anon;
