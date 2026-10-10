-- Phase 3: examination masters
-- Additive migration only. Does not alter existing attendance/auth/report-card tables.
create table if not exists public.exam_subjects (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  name text not null check (length(trim(name)) between 1 and 120),
  code text not null check (length(trim(code)) between 1 and 20),
  is_optional boolean not null default false,
  active boolean not null default true,
  created_by text not null default coalesce(auth.jwt() ->> 'email', ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (school_code, code)
);
create table if not exists public.exam_class_subjects (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  class_name text not null,
  section text not null,
  subject_id uuid not null references public.exam_subjects(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (school_code, class_name, section, subject_id)
);
create table if not exists public.exam_teacher_assignments (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  teacher_email text not null,
  class_name text not null,
  section text not null,
  subject_id uuid not null references public.exam_subjects(id) on delete restrict,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_code, teacher_email, class_name, section, subject_id)
);
create table if not exists public.exam_optional_students (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  student_id uuid not null references public.student_roster(id) on delete cascade,
  subject_id uuid not null references public.exam_subjects(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (school_code, student_id, subject_id)
);
create table if not exists public.exam_heads (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  name text not null check (length(trim(name)) between 1 and 80),
  max_marks numeric(7,2) not null check (max_marks > 0),
  pass_marks numeric(7,2) not null check (pass_marks >= 0 and pass_marks <= max_marks),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_code, name)
);
create table if not exists public.exam_types (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  name text not null check (length(trim(name)) between 1 and 80),
  display_order integer not null default 1 check (display_order > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_code, name)
);
create table if not exists public.exams (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  name text not null check (length(trim(name)) between 1 and 160),
  academic_year text not null check (length(trim(academic_year)) between 4 and 20),
  class_name text not null,
  section text not null,
  exam_type_id uuid not null references public.exam_types(id) on delete restrict,
  start_date date,
  end_date date,
  active boolean not null default true,
  created_by text not null default coalesce(auth.jwt() ->> 'email', ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_date is null or end_date is null or end_date >= start_date)
);
create index if not exists exam_class_subjects_lookup_idx on public.exam_class_subjects(school_code,class_name,section);
create index if not exists exam_teacher_assignments_lookup_idx on public.exam_teacher_assignments(school_code,lower(teacher_email),class_name,section) where active;
create index if not exists exam_optional_students_student_idx on public.exam_optional_students(school_code,student_id);
create index if not exists exams_class_year_idx on public.exams(school_code,academic_year,class_name,section) where active;

alter table public.exam_subjects enable row level security;
alter table public.exam_class_subjects enable row level security;
alter table public.exam_teacher_assignments enable row level security;
alter table public.exam_optional_students enable row level security;
alter table public.exam_heads enable row level security;
alter table public.exam_types enable row level security;
alter table public.exams enable row level security;

drop policy if exists exam_subjects_admin_all on public.exam_subjects;
create policy exam_subjects_admin_all on public.exam_subjects for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');
drop policy if exists exam_subjects_school_read on public.exam_subjects;
create policy exam_subjects_school_read on public.exam_subjects for select to authenticated
using (school_code='ashiana' and (
  (select private.is_admin()) or exists(select 1 from public.student_class_assignments a where a.school_code=exam_subjects.school_code and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and a.active)
  or exists(select 1 from public.student_subject_assignments sa where sa.school_code=exam_subjects.school_code and lower(sa.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and sa.active)
));
drop policy if exists exam_class_subjects_admin_all on public.exam_class_subjects;
create policy exam_class_subjects_admin_all on public.exam_class_subjects for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');
drop policy if exists exam_class_subjects_teacher_read on public.exam_class_subjects;
create policy exam_class_subjects_teacher_read on public.exam_class_subjects for select to authenticated
using (school_code='ashiana' and exists(select 1 from public.student_class_assignments a where a.school_code=exam_class_subjects.school_code and a.class_name=exam_class_subjects.class_name and a.section=exam_class_subjects.section and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and a.active));
drop policy if exists exam_teacher_assignments_admin_all on public.exam_teacher_assignments;
create policy exam_teacher_assignments_admin_all on public.exam_teacher_assignments for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');
drop policy if exists exam_teacher_assignments_teacher_read on public.exam_teacher_assignments;
create policy exam_teacher_assignments_teacher_read on public.exam_teacher_assignments for select to authenticated
using (school_code='ashiana' and lower(teacher_email)=lower(coalesce(auth.jwt()->>'email','')));
drop policy if exists exam_optional_students_admin_all on public.exam_optional_students;
create policy exam_optional_students_admin_all on public.exam_optional_students for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');
drop policy if exists exam_heads_admin_all on public.exam_heads;
create policy exam_heads_admin_all on public.exam_heads for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');
drop policy if exists exam_types_admin_all on public.exam_types;
create policy exam_types_admin_all on public.exam_types for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');
drop policy if exists exams_admin_all on public.exams;
create policy exams_admin_all on public.exams for all to authenticated
using ((select private.is_admin()) and school_code='ashiana')
with check ((select private.is_admin()) and school_code='ashiana');
drop policy if exists exams_teacher_read_assigned on public.exams;
create policy exams_teacher_read_assigned on public.exams for select to authenticated
using (school_code='ashiana' and (
 exists(select 1 from public.student_class_assignments a where a.school_code=exams.school_code and a.class_name=exams.class_name and a.section=exams.section and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and a.active)
 or exists(select 1 from public.student_subject_assignments sa where sa.school_code=exams.school_code and sa.class_name=exams.class_name and sa.section=exams.section and lower(sa.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and sa.active)
));
