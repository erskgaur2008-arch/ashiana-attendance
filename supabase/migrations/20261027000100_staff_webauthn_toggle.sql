-- Allow staff to turn PWA passkey attendance on/off without deleting their registered key.
alter table public.staff_webauthn_credentials
  add column if not exists enabled boolean not null default true;
