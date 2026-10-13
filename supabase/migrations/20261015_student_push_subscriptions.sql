-- Private device registrations for the RPC-authenticated student portal.
-- Rows are written only by the push-notifications Edge Function using service role.
-- This migration is additive and does not change existing student/auth/attendance data.
create table if not exists public.student_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  school_code text not null,
  enroll_no text not null,
  class_name text,
  section text,
  platform text not null check (platform in ('web', 'android')),
  endpoint text,
  subscription jsonb,
  device_token text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint student_push_subscriptions_platform_fields check (
    (platform = 'web' and endpoint is not null and subscription is not null and device_token is null)
    or
    (platform = 'android' and device_token is not null and endpoint is null and subscription is null)
  )
);

create unique index if not exists student_push_subscriptions_android_token_uidx
  on public.student_push_subscriptions(device_token)
  where platform = 'android';
create unique index if not exists student_push_subscriptions_web_endpoint_uidx
  on public.student_push_subscriptions(endpoint)
  where platform = 'web';
create index if not exists student_push_subscriptions_target_idx
  on public.student_push_subscriptions(school_code, class_name, section);
alter table public.student_push_subscriptions enable row level security;
revoke all on table public.student_push_subscriptions from anon, authenticated, public;
