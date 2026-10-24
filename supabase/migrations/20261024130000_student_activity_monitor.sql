-- Privacy-safe student login and push-delivery diagnostics.
-- Service-role only; never expose tokens, DOBs, payloads, or subscription secrets.
create table if not exists public.student_activity_monitor (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  enroll_no text not null,
  class_name text,
  section text,
  platform text check (platform in ('android','web','unknown')),
  event_type text not null check (event_type in ('login_success','push_delivery')),
  status text not null check (status in ('success','failed')),
  error_code text,
  created_at timestamptz not null default now()
);
create index if not exists student_activity_monitor_lookup_idx
  on public.student_activity_monitor (school_code, enroll_no, created_at desc);
create index if not exists student_activity_monitor_recent_idx
  on public.student_activity_monitor (school_code, event_type, created_at desc);
alter table public.student_activity_monitor enable row level security;
revoke all on public.student_activity_monitor from anon, authenticated;
grant all on public.student_activity_monitor to service_role;
