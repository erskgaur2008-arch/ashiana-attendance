-- Student session tokens (proposal; do not apply automatically).
-- Tokens are random bearer secrets. Only SHA-256 hashes are stored server-side.
-- This migration is intentionally isolated for review and must be tested against EduPunch-Test.

create table if not exists public.student_session_tokens (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.student_roster(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_used_at timestamptz
);

create index if not exists student_session_tokens_student_active_idx
  on public.student_session_tokens(student_id, expires_at)
  where revoked_at is null;

alter table public.student_session_tokens enable row level security;
revoke all on public.student_session_tokens from public, anon, authenticated;

-- Validate opaque bearer token; returns only the active student's UUID.
create or replace function public.student_session_student_id(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
begin
  if p_token is null or length(p_token) < 32 or length(p_token) > 256 then
    return null;
  end if;

  update public.student_session_tokens t
     set last_used_at = now()
   where t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and t.revoked_at is null
     and t.expires_at > now()
     and exists (
       select 1 from public.student_roster s
       where s.id = t.student_id
         and s.school_code = 'ashiana'
         and s.status = 'ACTIVE'
     )
  returning student_id into v_student_id;

  return v_student_id;
end;
$function$;

revoke all on function public.student_session_student_id(text) from public, anon, authenticated;

-- Login exchanges the existing DOB check for a random 30-day session token.
create or replace function public.student_session_start(
  p_school_code text,
  p_enroll_no text,
  p_dob_password text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_login jsonb;
  v_student_id uuid;
  v_token text;
begin
  v_login := public.student_login(p_school_code, p_enroll_no, p_dob_password);
  if coalesce((v_login->>'success')::boolean, false) is not true then
    return v_login;
  end if;

  v_student_id := (v_login->'student'->>'id')::uuid;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.student_session_tokens(student_id, token_hash, expires_at)
  values (
    v_student_id,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    now() + interval '30 days'
  );

  return jsonb_build_object(
    'success', true,
    'student', v_login->'student',
    'session_token', v_token,
    'expires_at', (now() + interval '30 days')
  );
end;
$function$;

revoke all on function public.student_session_start(text,text,text) from public;
grant execute on function public.student_session_start(text,text,text) to anon;

create or replace function public.student_session_revoke(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_token is null or length(p_token) < 32 or length(p_token) > 256 then
    return jsonb_build_object('success', true);
  end if;
  update public.student_session_tokens
     set revoked_at = now()
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and revoked_at is null;
  return jsonb_build_object('success', true);
end;
$function$;

revoke all on function public.student_session_revoke(text) from public;
grant execute on function public.student_session_revoke(text) to anon;

-- Return the existing portal bundle only after bearer-token validation.
create or replace function public.student_portal_bundle_by_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  s public.student_roster%rowtype;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select * into s
    from public.student_roster
   where id = v_student_id and school_code = 'ashiana' and status = 'ACTIVE';
  if not found then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  return jsonb_build_object(
    'success', true,
    'student', jsonb_build_object(
      'id',s.id,'enroll_no',s.enroll_no,'student_name',s.student_name,
      'class_name',s.class_name,'section',s.section,'roll_no',s.roll_no,
      'gender',s.gender,'category',s.category,'status',s.status,'dob',s.dob,
      'mother_name',s.mother_name,'father_name',s.father_name,'address',s.address,
      'phone_number',s.phone_number,'mode_of_transport',s.mode_of_transport,
      'photo_path',s.photo_path
    ),
    'attendance',(select coalesce(jsonb_agg(to_jsonb(a) order by a.attendance_date desc),'[]'::jsonb) from public.student_attendance a where a.school_code='ashiana' and a.student_id=s.id),
    'notices',(select coalesce(jsonb_agg(to_jsonb(n) order by n.publish_at desc),'[]'::jsonb) from public.student_notices n where n.school_code='ashiana' and n.active and (n.class_name is null or n.class_name=s.class_name) and (n.section is null or n.section=s.section)),
    'homework',(select coalesce(jsonb_agg(to_jsonb(h) order by h.due_date nulls last,h.created_at desc),'[]'::jsonb) from public.student_homework h where h.school_code='ashiana' and h.active and h.class_name=s.class_name and h.section=s.section),
    'timetable',(select coalesce(jsonb_agg(to_jsonb(t) order by t.day_of_week,t.period_no),'[]'::jsonb) from public.student_timetable t where t.school_code='ashiana' and t.active and t.class_name=s.class_name and t.section=s.section),
    'leave_requests',(select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at desc),'[]'::jsonb) from public.student_leave_requests l where l.school_code='ashiana' and l.student_id=s.id),
    'report_cards',(select coalesce(jsonb_agg(to_jsonb(r) order by r.academic_year desc,r.term desc),'[]'::jsonb) from public.student_report_cards r where r.school_code='ashiana' and r.student_id=s.id and r.published),
    'calendar',(select coalesce(jsonb_agg(to_jsonb(c) order by c.event_date),'[]'::jsonb) from public.student_calendar_events c where c.school_code='ashiana' and c.active and (c.class_name is null or c.class_name=s.class_name) and (c.section is null or c.section=s.section))
  );
end;
$function$;

revoke all on function public.student_portal_bundle_by_session(text) from public;
grant execute on function public.student_portal_bundle_by_session(text) to anon;
