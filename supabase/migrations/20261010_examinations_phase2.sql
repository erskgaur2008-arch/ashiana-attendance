-- Phase 2: Examination workflow masters and marks
-- Safe to include in a PR; do not apply to production until reviewed and approved.
begin;

create table if not exists public.exam_subjects (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  subject_name text not null,
  subject_code text,
  is_optional boolean not null default false,
  active boolean not null default true,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint exam_subjects_school_name_unique unique (school_code, subject_name)
);
create table if not exists public.exam_class_subjects (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  class_name text not null,
  section text not null default '',
  subject_id uuid not null references public.exam_subjects(id) on delete restrict,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint exam_class_subject_unique unique (school_code, class_name, section, subject_id)
);
create table if not exists public.exam_types (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  name text not null,
  academic_year text not null,
  sequence_no integer not null default 1,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint exam_types_school_year_name_unique unique (school_code, academic_year, name)
);
create table if not exists public.exam_heads (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  name text not null,
  default_max_marks numeric(7,2) not null default 100 check (default_max_marks > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint exam_heads_school_name_unique unique (school_code, name)
);
create table if not exists public.examinations (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  name text not null,
  academic_year text not null,
  exam_type_id uuid not null references public.exam_types(id) on delete restrict,
  class_name text not null,
  section text not null default '',
  start_date date,
  end_date date,
  status text not null default 'DRAFT' check (status in ('DRAFT','OPEN','CLOSED','PUBLISHED')),
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint examinations_scope_name_unique unique (school_code, academic_year, class_name, section, name)
);
create table if not exists public.examination_teacher_assignments (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  examination_id uuid not null references public.examinations(id) on delete cascade,
  subject_id uuid not null references public.exam_subjects(id) on delete restrict,
  teacher_email text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint exam_teacher_assignment_unique unique (school_code, examination_id, subject_id, teacher_email)
);
create table if not exists public.examination_optional_students (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  student_id uuid not null references public.student_roster(id) on delete cascade,
  subject_id uuid not null references public.exam_subjects(id) on delete restrict,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint examination_optional_student_unique unique (school_code, student_id, subject_id)
);
create table if not exists public.examination_marks (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  examination_id uuid not null references public.examinations(id) on delete cascade,
  student_id uuid not null references public.student_roster(id) on delete cascade,
  subject_id uuid not null references public.exam_subjects(id) on delete restrict,
  exam_head_id uuid references public.exam_heads(id) on delete restrict,
  maximum_marks numeric(7,2) not null check (maximum_marks > 0),
  marks_obtained numeric(7,2) check (marks_obtained >= 0 and marks_obtained <= maximum_marks),
  grade text,
  remarks text,
  entered_by text,
  published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint examination_marks_unique unique (school_code, examination_id, student_id, subject_id, exam_head_id)
);

create index if not exists exam_class_subjects_lookup_idx on public.exam_class_subjects (school_code, class_name, section, active);
create index if not exists examinations_class_year_idx on public.examinations (school_code, academic_year, class_name, section, status);
create index if not exists exam_teacher_assignments_email_idx on public.examination_teacher_assignments (school_code, lower(teacher_email), active);
create index if not exists examination_marks_student_idx on public.examination_marks (school_code, student_id, examination_id);
create index if not exists examination_marks_exam_idx on public.examination_marks (school_code, examination_id, subject_id);

alter table public.exam_subjects enable row level security;
alter table public.exam_class_subjects enable row level security;
alter table public.exam_types enable row level security;
alter table public.exam_heads enable row level security;
alter table public.examinations enable row level security;
alter table public.examination_teacher_assignments enable row level security;
alter table public.examination_optional_students enable row level security;
alter table public.examination_marks enable row level security;

-- Masters: authenticated admins manage; authenticated school members can read active entries.
drop policy if exists exam_subjects_admin_all on public.exam_subjects;
create policy exam_subjects_admin_all on public.exam_subjects for all to authenticated
using (private.is_admin() and school_code='ashiana')
with check (private.is_admin() and school_code='ashiana');
drop policy if exists exam_subjects_read_active on public.exam_subjects;
create policy exam_subjects_read_active on public.exam_subjects for select to authenticated
using (school_code='ashiana' and active);

drop policy if exists exam_class_subjects_admin_all on public.exam_class_subjects;
create policy exam_class_subjects_admin_all on public.exam_class_subjects for all to authenticated
using (private.is_admin() and school_code='ashiana')
with check (private.is_admin() and school_code='ashiana');
drop policy if exists exam_class_subjects_read_school on public.exam_class_subjects;
create policy exam_class_subjects_read_school on public.exam_class_subjects for select to authenticated
using (school_code='ashiana' and active);

drop policy if exists exam_types_admin_all on public.exam_types;
create policy exam_types_admin_all on public.exam_types for all to authenticated
using (private.is_admin() and school_code='ashiana')
with check (private.is_admin() and school_code='ashiana');
drop policy if exists exam_types_read_active on public.exam_types;
create policy exam_types_read_active on public.exam_types for select to authenticated
using (school_code='ashiana' and active);

drop policy if exists exam_heads_admin_all on public.exam_heads;
create policy exam_heads_admin_all on public.exam_heads for all to authenticated
using (private.is_admin() and school_code='ashiana')
with check (private.is_admin() and school_code='ashiana');
drop policy if exists exam_heads_read_active on public.exam_heads;
create policy exam_heads_read_active on public.exam_heads for select to authenticated
using (school_code='ashiana' and active);

-- Examination definitions: admins manage; assigned teachers can read only their allocated exams.
drop policy if exists examinations_admin_all on public.examinations;
create policy examinations_admin_all on public.examinations for all to authenticated
using (private.is_admin() and school_code='ashiana')
with check (private.is_admin() and school_code='ashiana');
drop policy if exists examinations_teacher_read_assigned on public.examinations;
create policy examinations_teacher_read_assigned on public.examinations for select to authenticated
using (school_code='ashiana' and exists (
  select 1 from public.examination_teacher_assignments a
  where a.examination_id=examinations.id and a.school_code=examinations.school_code
    and a.active and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email',''))
));

drop policy if exists examination_teacher_assignments_admin_all on public.examination_teacher_assignments;
create policy examination_teacher_assignments_admin_all on public.examination_teacher_assignments for all to authenticated
using (private.is_admin() and school_code='ashiana')
with check (private.is_admin() and school_code='ashiana');
drop policy if exists examination_teacher_assignments_teacher_read_self on public.examination_teacher_assignments;
create policy examination_teacher_assignments_teacher_read_self on public.examination_teacher_assignments for select to authenticated
using (school_code='ashiana' and lower(teacher_email)=lower(coalesce(auth.jwt()->>'email','')));

drop policy if exists examination_optional_students_admin_all on public.examination_optional_students;
create policy examination_optional_students_admin_all on public.examination_optional_students for all to authenticated
using (private.is_admin() and school_code='ashiana')
with check (private.is_admin() and school_code='ashiana');
drop policy if exists examination_optional_students_teacher_read_assigned on public.examination_optional_students;
create policy examination_optional_students_teacher_read_assigned on public.examination_optional_students for select to authenticated
using (school_code='ashiana' and exists (
  select 1 from public.student_roster s
  where s.id=examination_optional_students.student_id and s.school_code=examination_optional_students.school_code
    and (exists (select 1 from public.student_class_assignments a where a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section and a.active and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')))
      or exists (select 1 from public.student_subject_assignments sa where sa.school_code=s.school_code and sa.class_name=s.class_name and sa.section=s.section and sa.active and lower(sa.teacher_email)=lower(coalesce(auth.jwt()->>'email',''))))
));

-- Teachers can read marks for assigned exam/subject and insert/update only their allocated subject.
drop policy if exists examination_marks_admin_all on public.examination_marks;
create policy examination_marks_admin_all on public.examination_marks for all to authenticated
using (private.is_admin() and school_code='ashiana')
with check (private.is_admin() and school_code='ashiana');
drop policy if exists examination_marks_teacher_select on public.examination_marks;
create policy examination_marks_teacher_select on public.examination_marks for select to authenticated
using (school_code='ashiana' and exists (
  select 1 from public.examination_teacher_assignments a
  where a.school_code=examination_marks.school_code and a.examination_id=examination_marks.examination_id
    and a.subject_id=examination_marks.subject_id and a.active
    and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email',''))
));
drop policy if exists examination_marks_teacher_insert on public.examination_marks;
create policy examination_marks_teacher_insert on public.examination_marks for insert to authenticated
with check (school_code='ashiana' and lower(coalesce(entered_by,''))=lower(coalesce(auth.jwt()->>'email',''))
  and exists (select 1 from public.examination_teacher_assignments a
    where a.school_code=examination_marks.school_code and a.examination_id=examination_marks.examination_id
      and a.subject_id=examination_marks.subject_id and a.active
      and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')))
  and exists (select 1 from public.examinations e where e.id=examination_marks.examination_id and e.school_code=examination_marks.school_code and e.status='OPEN')
  and exists (select 1 from public.student_roster s join public.examinations e on e.id=examination_marks.examination_id
    where s.id=examination_marks.student_id and s.school_code=examination_marks.school_code and s.class_name=e.class_name and s.section=e.section));
drop policy if exists examination_marks_teacher_update on public.examination_marks;
create policy examination_marks_teacher_update on public.examination_marks for update to authenticated
using (school_code='ashiana' and exists (
  select 1 from public.examination_teacher_assignments a
  where a.school_code=examination_marks.school_code and a.examination_id=examination_marks.examination_id
    and a.subject_id=examination_marks.subject_id and a.active
    and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email',''))
))
with check (school_code='ashiana' and lower(coalesce(entered_by,''))=lower(coalesce(auth.jwt()->>'email',''))
  and exists (select 1 from public.examination_teacher_assignments a
    where a.school_code=examination_marks.school_code and a.examination_id=examination_marks.examination_id
      and a.subject_id=examination_marks.subject_id and a.active
      and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')))
  and exists (select 1 from public.examinations e where e.id=examination_marks.examination_id and e.school_code=examination_marks.school_code and e.status='OPEN')
  and exists (select 1 from public.student_roster s join public.examinations e on e.id=examination_marks.examination_id
    where s.id=examination_marks.student_id and s.school_code=examination_marks.school_code and s.class_name=e.class_name and s.section=e.section));

grant select, insert, update, delete on public.exam_subjects, public.exam_class_subjects, public.exam_types, public.exam_heads, public.examinations, public.examination_teacher_assignments, public.examination_optional_students, public.examination_marks to authenticated;

commit;
