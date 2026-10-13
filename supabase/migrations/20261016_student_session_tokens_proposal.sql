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

create table if not exists public.student_leave_requests (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  student_id uuid not null references public.student_roster(id) on delete cascade,
  enroll_no text not null,
  from_date date not null,
  to_date date not null,
  reason text not null,
  status text not null default 'PENDING',
  created_at timestamptz not null default now()
);

alter table public.student_leave_requests enable row level security;
revoke all on public.student_leave_requests from public, anon, authenticated;

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
         and lower(coalesce(s.status, '')) = 'active'
     )
  returning student_id into v_student_id;

  return v_student_id;
end;
$function$;

revoke all on function public.student_session_student_id(text) from public, anon, authenticated;
grant execute on function public.student_session_student_id(text) to service_role;

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

-- Return the established portal bundle after validating the opaque session token.
-- Calling the existing bundle preserves the production portal's current feature set.
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
  -- The test project does not yet include the legacy leave RPC; expose the
  -- minimal test-only leave table in the bundle when that RPC is absent.
  if to_regprocedure('public.student_submit_leave(text,text,date,date,text)') is null then
    v_bundle := jsonb_set(v_bundle, '{leave_requests}', coalesce((
      select jsonb_agg(to_jsonb(l) order by l.created_at desc)
      from public.student_leave_requests l
      where l.student_id = s.id and l.school_code = 'ashiana'
    ), '[]'::jsonb), true);
  end if;
  return v_bundle;
end;
$function$;

revoke all on function public.student_portal_bundle_by_session(text) from public;
grant execute on function public.student_portal_bundle_by_session(text) to anon;

-- Reuse the existing, production-tested leave function when it exists. The
-- test project may not have that feature installed yet, so the migration still
-- installs safely there without referencing a missing function at creation time.
create or replace function public.student_submit_leave_by_session(
  p_token text,
  p_from_date date,
  p_to_date date,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  s public.student_roster%rowtype;
  v_result jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED', 'message', 'Please sign in again.');
  end if;
  select * into s from public.student_roster
   where id = v_student_id and school_code = 'ashiana'
     and lower(coalesce(status, '')) = 'active';
  if not found then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED', 'message', 'Please sign in again.');
  end if;
  if p_from_date is null or p_to_date is null or p_from_date > p_to_date
     or nullif(btrim(p_reason), '') is null then
    return jsonb_build_object('success', false, 'message', 'Please provide valid leave dates and reason.');
  end if;

  if to_regprocedure('public.student_submit_leave(text,text,date,date,text)') is null then
    if exists (
      select 1 from public.student_leave_requests l
       where l.student_id = s.id and l.status = 'PENDING'
         and l.from_date <= p_to_date and l.to_date >= p_from_date
    ) then
      return jsonb_build_object('success', false, 'message', 'A leave request for these dates is already pending.');
    end if;
    insert into public.student_leave_requests(school_code, student_id, enroll_no, from_date, to_date, reason, status)
    values ('ashiana', s.id, s.enroll_no, p_from_date, p_to_date, btrim(p_reason), 'PENDING');
    return jsonb_build_object('success', true, 'message', 'Leave request submitted.');
  end if;

  execute 'select public.student_submit_leave($1,$2,$3,$4,$5)'
    into v_result
    using s.enroll_no, to_char(s.dob, 'DDMMYYYY'), p_from_date, p_to_date, p_reason;
  return coalesce(v_result, jsonb_build_object('success', false, 'message', 'Leave request failed.'));
end;
$function$;

revoke all on function public.student_submit_leave_by_session(text,date,date,text) from public;
grant execute on function public.student_submit_leave_by_session(text,date,date,text) to anon;
