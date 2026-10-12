-- Security Phase 2
-- RUN ORDER: deploy the new edge functions and the new index.html FIRST,
-- then run this file (section 3 revokes browser access to a PIN function).
--
-- 1. Student rate limiting: one shared bucket per student, per-IP bucket,
--    key-length cap, automatic cleanup.
-- 2. Leave request size limits.
-- 3. Revoke browser access to verify_staff_pin_internal (PIN-guessing oracle).
-- 4. Per-user daily quota for the AI assistant.

-- ---------------------------------------------------------------------------
-- 1. Rate limiting
-- ---------------------------------------------------------------------------

-- Canonical key: 'ashiana:X', 'portal:X', 'leave:X', 'photo:X', 'X' all map to
-- the same 'student:X' bucket, so attackers cannot multiply guesses by
-- alternating between login / portal / leave / photo endpoints.
create or replace function private.normalize_student_login_key(p_key text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when lower(trim(coalesce(p_key, ''))) like 'ip:%' then lower(trim(p_key))
    else 'student:' || regexp_replace(upper(trim(coalesce(p_key, ''))), '^(ASHIANA|PORTAL|LEAVE|PHOTO):', '')
  end
$$;

create or replace function private.bump_rate_limit(
  p_key text,
  p_max integer,
  p_window integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := encode(extensions.digest(p_key, 'sha256'), 'hex');
  v_row private.student_login_rate_limits%rowtype;
  v_now timestamptz := clock_timestamp();
  v_retry integer;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(v_hash));

  select * into v_row
    from private.student_login_rate_limits
   where login_key = v_hash
   for update;

  if not found then
    insert into private.student_login_rate_limits(login_key, window_started_at, attempt_count, updated_at)
    values (v_hash, v_now, 1, v_now);
    return jsonb_build_object('allowed', true, 'attempts_remaining', greatest(p_max - 1, 0));
  end if;

  if v_row.window_started_at + make_interval(secs => p_window) <= v_now then
    update private.student_login_rate_limits
       set window_started_at = v_now, attempt_count = 1, updated_at = v_now
     where login_key = v_hash;
    return jsonb_build_object('allowed', true, 'attempts_remaining', greatest(p_max - 1, 0));
  end if;

  if v_row.attempt_count >= p_max then
    v_retry := greatest(1, ceil(extract(epoch from (
      v_row.window_started_at + make_interval(secs => p_window) - v_now
    )))::integer);
    update private.student_login_rate_limits set updated_at = v_now where login_key = v_hash;
    return jsonb_build_object('allowed', false, 'retry_after_seconds', v_retry);
  end if;

  update private.student_login_rate_limits
     set attempt_count = attempt_count + 1, updated_at = v_now
   where login_key = v_hash;

  return jsonb_build_object('allowed', true, 'attempts_remaining', greatest(p_max - v_row.attempt_count - 1, 0));
end;
$$;

revoke all on function private.bump_rate_limit(text, integer, integer) from public, anon, authenticated;
revoke all on function private.normalize_student_login_key(text) from public, anon, authenticated;

create or replace function public.consume_student_login_attempt(
  p_login_key text,
  p_max_attempts integer default 6,
  p_window_seconds integer default 600
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_key text;
  v_is_ip boolean;
  v_headers json;
  v_ip text;
  v_res jsonb;
  v_max integer;
  v_window integer;
begin
  -- reject empty / oversized keys (stops attacker-chosen key flooding)
  if coalesce(trim(p_login_key), '') = '' or length(p_login_key) > 200 then
    return jsonb_build_object('allowed', false, 'retry_after_seconds', greatest(coalesce(p_window_seconds, 600), 1));
  end if;

  v_key := private.normalize_student_login_key(p_login_key);
  v_is_ip := v_key like 'ip:%';

  -- opportunistic cleanup of stale buckets
  if random() < 0.02 then
    delete from private.student_login_rate_limits
     where updated_at < now() - interval '2 days';
  end if;

  if v_is_ip then
    v_max := greatest(coalesce(p_max_attempts, 300), 1);
    v_window := greatest(coalesce(p_window_seconds, 600), 1);
  else
    -- per-student: at most 5 failures per 30 minutes, whatever the caller asks
    v_max := least(greatest(coalesce(p_max_attempts, 5), 1), 5);
    v_window := greatest(coalesce(p_window_seconds, 1800), 1800);

    -- per-IP bucket for calls that come straight from a browser (PostgREST)
    begin
      v_headers := nullif(current_setting('request.headers', true), '')::json;
    exception when others then
      v_headers := null;
    end;
    v_ip := nullif(trim(coalesce(v_headers ->> 'cf-connecting-ip', v_headers ->> 'x-real-ip', '')), '');
    if v_ip is not null then
      v_res := private.bump_rate_limit('ip:' || lower(v_ip), 300, 600);
      if not coalesce((v_res ->> 'allowed')::boolean, false) then
        return v_res;
      end if;
    end if;
  end if;

  return private.bump_rate_limit(v_key, v_max, v_window);
end;
$function$;

create or replace function public.clear_student_login_attempt(p_login_key text)
returns void
language sql
security definer
set search_path = ''
as $function$
  delete from private.student_login_rate_limits
   where login_key = encode(
     extensions.digest(private.normalize_student_login_key(p_login_key), 'sha256'),
     'hex'
   );
$function$;

revoke all on function public.consume_student_login_attempt(text, integer, integer) from public, anon, authenticated;
revoke all on function public.clear_student_login_attempt(text) from public, anon, authenticated;
grant execute on function public.consume_student_login_attempt(text, integer, integer) to postgres, service_role;
grant execute on function public.clear_student_login_attempt(text) to postgres, service_role;

-- ---------------------------------------------------------------------------
-- 2. Leave request size limits (NOT VALID: existing rows are not re-checked)
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'student_leave_reason_len_chk') then
    alter table public.student_leave_requests
      add constraint student_leave_reason_len_chk check (char_length(reason) <= 1000) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'student_leave_range_chk') then
    alter table public.student_leave_requests
      add constraint student_leave_range_chk check (to_date - from_date <= 120) not valid;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. verify_staff_pin_internal must only be callable by the server
--    (browsers could otherwise use it to guess any staff PIN with no lockout)
-- ---------------------------------------------------------------------------
revoke execute on function public.verify_staff_pin_internal(text, text) from public, anon, authenticated;
grant  execute on function public.verify_staff_pin_internal(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 4. AI assistant daily quota
-- ---------------------------------------------------------------------------
create table if not exists private.ai_usage (
  user_id uuid not null,
  usage_date date not null,
  request_count integer not null default 0,
  primary key (user_id, usage_date)
);
revoke all on table private.ai_usage from public, anon, authenticated;

create or replace function public.consume_ai_quota(p_user_id uuid, p_max integer default 40)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
  v_count integer;
begin
  if p_user_id is null then
    return jsonb_build_object('allowed', false);
  end if;

  if random() < 0.02 then
    delete from private.ai_usage where usage_date < v_day - 7;
  end if;

  insert into private.ai_usage(user_id, usage_date, request_count)
  values (p_user_id, v_day, 1)
  on conflict (user_id, usage_date)
  do update set request_count = private.ai_usage.request_count + 1
  returning request_count into v_count;

  return jsonb_build_object('allowed', v_count <= greatest(coalesce(p_max, 40), 1), 'used', v_count);
end;
$function$;

revoke all on function public.consume_ai_quota(uuid, integer) from public, anon, authenticated;
grant execute on function public.consume_ai_quota(uuid, integer) to postgres, service_role;

notify pgrst, 'reload schema';
