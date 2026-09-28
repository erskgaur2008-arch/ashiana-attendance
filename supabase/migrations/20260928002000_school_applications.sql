-- School onboarding request queue (staged only; do not apply to production).
-- Approval and tenant provisioning are intentionally server-side only.
begin;

create table if not exists public.school_applications (
  id uuid primary key default gen_random_uuid(),
  school_name text not null check (length(btrim(school_name)) between 2 and 160),
  requested_slug text not null check (
    requested_slug = lower(requested_slug)
    and requested_slug ~ '^[a-z0-9](?:[a-z0-9-]{1,48}[a-z0-9])?$'
  ),
  applicant_user_id uuid not null references auth.users(id) on delete restrict,
  contact_name text not null check (length(btrim(contact_name)) between 2 and 120),
  contact_email text not null check (contact_email = lower(btrim(contact_email))),
  contact_phone text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  review_note text,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists school_applications_applicant_idx
  on public.school_applications(applicant_user_id, created_at desc);
create index if not exists school_applications_pending_idx
  on public.school_applications(created_at desc) where status = 'pending';
create unique index if not exists school_applications_one_pending_slug_idx
  on public.school_applications(requested_slug) where status = 'pending';

alter table public.school_applications enable row level security;

drop policy if exists school_applications_submit_own on public.school_applications;
create policy school_applications_submit_own
  on public.school_applications for insert to authenticated
  with check (
    applicant_user_id = (select auth.uid())
    and lower(contact_email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  );

drop policy if exists school_applications_read_own on public.school_applications;
create policy school_applications_read_own
  on public.school_applications for select to authenticated
  using (applicant_user_id = (select auth.uid()));

drop policy if exists school_applications_platform_approver_read on public.school_applications;
create policy school_applications_platform_approver_read
  on public.school_applications for select to authenticated
  using (
    lower(coalesce((select auth.jwt() ->> 'email'), '')) = 'rajkumargaur54@gmail.com'
    and coalesce((select auth.jwt() ->> 'email_verified'), 'false') = 'true'
  );

revoke all on public.school_applications from anon, authenticated;
grant select, insert on public.school_applications to authenticated;

commit;
