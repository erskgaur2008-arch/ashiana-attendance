-- Admin + Student WebAuthn passkeys.
-- Public-key credentials only. No biometric images or private keys are stored.
-- All tables and RPCs are restricted to service_role; Edge Function verifies identity.
begin;

create table if not exists public.portal_webauthn_credentials (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('admin','student')),
  subject_id text not null,
  credential_id text not null unique,
  public_key text not null,
  counter bigint not null default 0,
  transports text[] not null default '{}',
  device_type text,
  backed_up boolean not null default false,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  unique(subject_type, subject_id, credential_id)
);

create index if not exists portal_webauthn_credentials_subject_idx
  on public.portal_webauthn_credentials(subject_type, subject_id, enabled);

create table if not exists public.portal_webauthn_challenges (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('admin','student')),
  subject_id text not null,
  challenge text not null,
  purpose text not null check (purpose in ('registration','authentication')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists portal_webauthn_challenges_subject_idx
  on public.portal_webauthn_challenges(subject_type, subject_id, purpose, expires_at);

alter table public.portal_webauthn_credentials enable row level security;
alter table public.portal_webauthn_challenges enable row level security;
revoke all on public.portal_webauthn_credentials from public, anon, authenticated;
revoke all on public.portal_webauthn_challenges from public, anon, authenticated;
grant all on public.portal_webauthn_credentials to service_role;
grant all on public.portal_webauthn_challenges to service_role;

-- Atomically consume a single unexpired challenge. The Edge Function verifies
-- the returned challenge against the signed WebAuthn response.
create or replace function public.consume_portal_webauthn_challenge(
  p_subject_type text, p_subject_id text, p_purpose text
) returns text
language plpgsql security definer set search_path = ''
as $function$
declare v_challenge text;
begin
  if p_subject_type not in ('admin','student')
     or p_purpose not in ('registration','authentication')
     or p_subject_id is null or length(p_subject_id) < 1 or length(p_subject_id) > 256 then
    return null;
  end if;
  delete from public.portal_webauthn_challenges c
   where c.id = (
     select c2.id from public.portal_webauthn_challenges c2
      where c2.subject_type = p_subject_type
        and c2.subject_id = p_subject_id
        and c2.purpose = p_purpose
        and c2.expires_at > now()
      order by c2.created_at desc
      limit 1
      for update skip locked
   )
  returning challenge into v_challenge;
  delete from public.portal_webauthn_challenges
   where subject_type = p_subject_type and subject_id = p_subject_id
     and purpose = p_purpose and expires_at <= now();
  return v_challenge;
end;
$function$;

revoke all on function public.consume_portal_webauthn_challenge(text,text,text) from public, anon, authenticated;
grant execute on function public.consume_portal_webauthn_challenge(text,text,text) to service_role;
commit;
