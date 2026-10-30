-- Event-wise school photo gallery. Private storage; all access is mediated by the event-photo-gallery Edge Function.
begin;
create table if not exists public.school_events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 2 and 180),
  description text not null default '' check (length(description) <= 3000),
  event_date date not null,
  status text not null default 'DRAFT' check (status in ('DRAFT','PUBLISHED','ARCHIVED')),
  audience_type text not null default 'ALL' check (audience_type in ('ALL','CLASS','SECTION')),
  class_name text,
  section text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((audience_type='ALL' and class_name is null and section is null)
      or (audience_type='CLASS' and class_name is not null and section is null)
      or (audience_type='SECTION' and class_name is not null and section is not null))
);
create index if not exists school_events_published_date_idx on public.school_events(status,event_date desc);
create index if not exists school_events_audience_idx on public.school_events(audience_type,class_name,section);
create table if not exists public.school_event_photos (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.school_events(id) on delete cascade,
  storage_path text not null unique,
  caption text not null default '' check (length(caption) <= 500),
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp')),
  byte_size integer not null check (byte_size > 0 and byte_size <= 1048576),
  created_at timestamptz not null default now()
);
create index if not exists school_event_photos_event_idx on public.school_event_photos(event_id,created_at);
alter table public.school_events enable row level security;
alter table public.school_event_photos enable row level security;
revoke all on public.school_events from anon, authenticated;
revoke all on public.school_event_photos from anon, authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('school-event-photos','school-event-photos',false,1048576,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=1048576,allowed_mime_types=excluded.allowed_mime_types;
commit;
