-- One-time, short-lived authorization issued only after verified staff WebAuthn assertion.
create table if not exists public.staff_webauthn_verified_sessions (
  token_hash text primary key,
  staff_id text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.staff_webauthn_verified_sessions enable row level security;
revoke all on public.staff_webauthn_verified_sessions from anon, authenticated;
grant all on public.staff_webauthn_verified_sessions to service_role;

-- Atomic consume prevents a passkey authorization from being replayed for two punches.
create or replace function public.consume_staff_webauthn_attendance_token(
  p_token_hash text,
  p_staff_id text
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  delete from public.staff_webauthn_verified_sessions
   where token_hash = p_token_hash
     and staff_id = p_staff_id
     and expires_at > now();
  get diagnostics v_deleted = row_count;
  return v_deleted = 1;
end;
$$;
revoke all on function public.consume_staff_webauthn_attendance_token(text, text) from public, anon, authenticated;
grant execute on function public.consume_staff_webauthn_attendance_token(text, text) to service_role;
