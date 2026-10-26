-- Live staff location tracking (last-known point only; no breadcrumb history).
-- All reads/writes go through the authenticated staff-live-location Edge Function.
create table if not exists public.staff_live_locations (
  staff_id text primary key references public.staff(id) on delete cascade,
  sharing_enabled boolean not null default false,
  latitude double precision,
  longitude double precision,
  accuracy_m double precision,
  captured_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint staff_live_locations_latitude_range check (latitude is null or latitude between -90 and 90),
  constraint staff_live_locations_longitude_range check (longitude is null or longitude between -180 and 180),
  constraint staff_live_locations_accuracy_positive check (accuracy_m is null or accuracy_m > 0)
);
create index if not exists staff_live_locations_updated_at_idx
  on public.staff_live_locations (updated_at desc) where sharing_enabled = true;
alter table public.staff_live_locations enable row level security;
revoke all on public.staff_live_locations from anon, authenticated;
grant all on public.staff_live_locations to service_role;
comment on table public.staff_live_locations is 'Latest location only while staff member explicitly enables work-hours location sharing. No location history is stored.';
