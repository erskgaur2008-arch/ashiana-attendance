-- Auditable requests only: this table never mutates attendance_punches.
create table if not exists public.attendance_punch_correction_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id text not null references public.staff(id),
  emp_id text not null,
  staff_name text not null,
  attendance_date date not null,
  original_punch_ids text[] not null default '{}',
  original_punch_snapshot jsonb not null default '[]'::jsonb,
  proposed_change jsonb not null,
  evidence_reference text not null,
  reviewer_reason text not null,
  requested_by_email text not null,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','CANCELLED')),
  reviewed_by_email text,
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint punch_correction_evidence_nonempty check (length(trim(evidence_reference)) > 0),
  constraint punch_correction_reason_nonempty check (length(trim(reviewer_reason)) > 0)
);
create index if not exists idx_punch_correction_status_date
  on public.attendance_punch_correction_requests(status, attendance_date desc);
create index if not exists idx_punch_correction_staff_date
  on public.attendance_punch_correction_requests(staff_id, attendance_date desc);
alter table public.attendance_punch_correction_requests enable row level security;
revoke all on public.attendance_punch_correction_requests from anon, authenticated;
grant all on public.attendance_punch_correction_requests to service_role;

create unique index if not exists uq_punch_correction_pending_staff_date
  on public.attendance_punch_correction_requests(staff_id, attendance_date)
  where status = 'PENDING';
