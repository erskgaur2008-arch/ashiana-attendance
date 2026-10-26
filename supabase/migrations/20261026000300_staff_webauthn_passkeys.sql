-- Staff WebAuthn/passkey credentials for PWA biometric verification.
-- No fingerprint or face images are stored; only public-key credentials.
-- Access is restricted to service-role Edge Functions. No client grants are added.

create table if not exists public.staff_webauthn_credentials (
  id uuid primary key default gen_random_uuid(),
  staff_id text not null,
  credential_id text not null unique,
  public_key text not null,
  counter bigint not null default 0,
  transports text[] not null default '{}',
  device_type text,
  backed_up boolean not null default false,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  unique (staff_id, credential_id)
);

create index if not exists staff_webauthn_credentials_staff_id_idx
  on public.staff_webauthn_credentials (staff_id);

create table if not exists public.staff_webauthn_challenges (
  id uuid primary key default gen_random_uuid(),
  staff_id text not null,
  challenge text not null,
  purpose text not null check (purpose in ('registration', 'attendance')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists staff_webauthn_challenges_staff_purpose_idx
  on public.staff_webauthn_challenges (staff_id, purpose, expires_at);

alter table public.staff_webauthn_credentials enable row level security;
alter table public.staff_webauthn_challenges enable row level security;

revoke all on public.staff_webauthn_credentials from anon, authenticated;
revoke all on public.staff_webauthn_challenges from anon, authenticated;
grant all on public.staff_webauthn_credentials to service_role;
grant all on public.staff_webauthn_challenges to service_role;
