-- Fees Management schema for Ashiana Attendance.
-- Additive only. Do not apply to production until the reviewed PR is approved.
begin;

create table if not exists public.fee_academic_years (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  label text not null,
  starts_on date not null,
  ends_on date not null,
  is_active boolean not null default false,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (starts_on <= ends_on),
  unique (school_code, label)
);
create unique index if not exists fee_academic_year_one_active_per_school
  on public.fee_academic_years(school_code) where is_active;

create table if not exists public.fee_structures (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  academic_year_id uuid not null references public.fee_academic_years(id),
  class_name text not null,
  fee_name text not null,
  amount_paise bigint not null check (amount_paise >= 0),
  is_mandatory boolean not null default true,
  due_date date,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (academic_year_id, class_name, fee_name)
);

create table if not exists public.student_fee_accounts (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  academic_year_id uuid not null references public.fee_academic_years(id),
  student_id uuid not null references public.student_roster(id),
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (academic_year_id, student_id)
);

create table if not exists public.fee_installments (
  id uuid primary key default gen_random_uuid(),
  fee_account_id uuid not null references public.student_fee_accounts(id),
  fee_structure_id uuid not null references public.fee_structures(id),
  installment_no integer not null check (installment_no > 0),
  amount_paise bigint not null check (amount_paise >= 0),
  due_date date not null,
  created_at timestamptz not null default now(),
  unique (fee_account_id, fee_structure_id, installment_no)
);

create table if not exists public.fee_discount_requests (
  id uuid primary key default gen_random_uuid(),
  fee_account_id uuid not null references public.student_fee_accounts(id),
  amount_paise bigint not null check (amount_paise > 0),
  reason text not null check (length(trim(reason)) between 3 and 1000),
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED')),
  requested_by uuid,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  check ((status = 'PENDING' and reviewed_at is null and reviewed_by is null)
      or (status <> 'PENDING' and reviewed_at is not null and reviewed_by is not null))
);

create table if not exists public.fee_payment_submissions (
  id uuid primary key default gen_random_uuid(),
  fee_account_id uuid not null references public.student_fee_accounts(id),
  amount_paise bigint not null check (amount_paise > 0),
  upi_reference text not null check (length(trim(upi_reference)) between 6 and 120),
  proof_object_path text not null,
  student_note text,
  status text not null default 'PENDING_ADMIN'
    check (status in ('PENDING_ADMIN','PENDING_PRINCIPAL','CONFIRMED','REJECTED')),
  submitted_by_student_id uuid not null references public.student_roster(id),
  admin_reviewed_by uuid,
  admin_reviewed_at timestamptz,
  principal_confirmed_by uuid,
  principal_confirmed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  check (status not in ('PENDING_PRINCIPAL','CONFIRMED') or
         (admin_reviewed_by is not null and admin_reviewed_at is not null)),
  check (status <> 'CONFIRMED' or
         (principal_confirmed_by is not null and principal_confirmed_at is not null
          and principal_confirmed_by <> admin_reviewed_by)),
  check (status <> 'REJECTED' or rejection_reason is not null)
);
create unique index if not exists fee_payment_reference_unique
  on public.fee_payment_submissions (lower(trim(upi_reference)));
create index if not exists fee_payment_review_queue_idx
  on public.fee_payment_submissions(status, created_at);

create table if not exists public.fee_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  fee_account_id uuid not null references public.student_fee_accounts(id),
  payment_submission_id uuid references public.fee_payment_submissions(id),
  entry_type text not null check (entry_type in ('PAYMENT','REVERSAL','ADJUSTMENT')),
  amount_paise bigint not null check (amount_paise <> 0),
  description text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  reverses_entry_id uuid references public.fee_ledger_entries(id),
  unique (payment_submission_id),
  check ((entry_type = 'PAYMENT' and amount_paise > 0 and reverses_entry_id is null)
      or entry_type <> 'PAYMENT')
);

create table if not exists public.fee_receipts (
  id uuid primary key default gen_random_uuid(),
  receipt_number text not null unique,
  fee_account_id uuid not null references public.student_fee_accounts(id),
  payment_submission_id uuid not null unique references public.fee_payment_submissions(id),
  amount_paise bigint not null check (amount_paise > 0),
  issued_at timestamptz not null default now(),
  issued_by uuid
);

create table if not exists public.fee_audit_log (
  id bigint generated always as identity primary key,
  school_code text not null default 'ashiana',
  actor_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists fee_audit_log_created_idx on public.fee_audit_log(created_at desc);

create table if not exists public.fee_principal_approvers (
  user_id uuid primary key,
  school_code text not null default 'ashiana',
  is_enabled boolean not null default true,
  assigned_by uuid not null,
  assigned_at timestamptz not null default now()
);

create table if not exists public.fee_reminder_attempts (
  id uuid primary key default gen_random_uuid(),
  fee_account_id uuid not null references public.student_fee_accounts(id),
  installment_id uuid references public.fee_installments(id),
  reminder_kind text not null check (reminder_kind in ('IN_APP','PUSH')),
  due_date date not null,
  outcome text not null default 'QUEUED' check (outcome in ('QUEUED','SENT','FAILED','SUPPRESSED')),
  reason text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  unique (fee_account_id, installment_id, reminder_kind, due_date)
);

alter table public.fee_academic_years enable row level security;
alter table public.fee_structures enable row level security;
alter table public.student_fee_accounts enable row level security;
alter table public.fee_installments enable row level security;
alter table public.fee_discount_requests enable row level security;
alter table public.fee_payment_submissions enable row level security;
alter table public.fee_ledger_entries enable row level security;
alter table public.fee_receipts enable row level security;
alter table public.fee_audit_log enable row level security;
alter table public.fee_principal_approvers enable row level security;
alter table public.fee_reminder_attempts enable row level security;

revoke all on public.fee_academic_years, public.fee_structures, public.student_fee_accounts,
 public.fee_installments, public.fee_discount_requests, public.fee_payment_submissions,
 public.fee_ledger_entries, public.fee_receipts, public.fee_audit_log,
 public.fee_principal_approvers, public.fee_reminder_attempts from public, anon, authenticated;

commit;
