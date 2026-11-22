-- Device-bound Student biometric credentials.
-- The native biometric store holds a random device secret; the database stores
-- only its SHA-256 hash. Active Student sessions remain separate and revocable.

create table if not exists public.student_biometric_credentials (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.student_roster(id) on delete cascade,
  device_secret_hash text not null unique,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  last_used_at timestamptz
);

alter table public.student_biometric_credentials enable row level security;
revoke all on public.student_biometric_credentials from public, anon, authenticated;

create index if not exists student_biometric_credentials_student_active_idx
  on public.student_biometric_credentials(student_id, created_at desc)
  where revoked_at is null;

create or replace function public.student_biometric_enroll(
  p_session_token text,
  p_device_secret text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_hash text;
begin
  if p_device_secret is null or length(p_device_secret) <> 64
     or p_device_secret !~ '^[a-fA-F0-9]{64}$' then
    return jsonb_build_object('success', false, 'code', 'INVALID_DEVICE_CREDENTIAL');
  end if;

  v_student_id := public.student_session_student_id(p_session_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  v_hash := encode(extensions.digest(lower(p_device_secret), 'sha256'), 'hex');
  insert into public.student_biometric_credentials(student_id, device_secret_hash)
  values (v_student_id, v_hash)
  on conflict (device_secret_hash) do update
    set student_id = excluded.student_id,
        revoked_at = null,
        created_at = now(),
        last_used_at = null;

  return jsonb_build_object('success', true);
end;
$function$;

create or replace function public.student_biometric_login(p_device_secret text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_token text;
begin
  if p_device_secret is null or length(p_device_secret) <> 64
     or p_device_secret !~ '^[a-fA-F0-9]{64}$' then
    return jsonb_build_object('success', false, 'code', 'INVALID_DEVICE_CREDENTIAL');
  end if;

  update public.student_biometric_credentials c
     set last_used_at = now()
   where c.device_secret_hash = encode(extensions.digest(lower(p_device_secret), 'sha256'), 'hex')
     and c.revoked_at is null
     and exists (
       select 1 from public.student_roster s
        where s.id = c.student_id
          and s.school_code = 'ashiana'
          and lower(coalesce(s.status, '')) = 'active'
     )
  returning c.student_id into v_student_id;

  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_BIOMETRIC_NOT_REGISTERED');
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.student_session_tokens(student_id, token_hash, expires_at)
  values (
    v_student_id,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    now() + interval '30 days'
  );

  return jsonb_build_object(
    'success', true,
    'session_token', v_token,
    'expires_in', 2592000
  );
end;
$function$;

create or replace function public.student_biometric_revoke(p_device_secret text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_device_secret is null or length(p_device_secret) <> 64
     or p_device_secret !~ '^[a-fA-F0-9]{64}$' then
    return jsonb_build_object('success', true);
  end if;

  update public.student_biometric_credentials
     set revoked_at = now()
   where device_secret_hash = encode(extensions.digest(lower(p_device_secret), 'sha256'), 'hex')
     and revoked_at is null;

  return jsonb_build_object('success', true);
end;
$function$;

revoke all on function public.student_biometric_enroll(text, text) from public, authenticated;
revoke all on function public.student_biometric_login(text) from public, authenticated;
revoke all on function public.student_biometric_revoke(text) from public, authenticated;
grant execute on function public.student_biometric_enroll(text, text) to anon;
grant execute on function public.student_biometric_login(text) to anon;
grant execute on function public.student_biometric_revoke(text) to anon;
