-- Ashiana Attendance: examination configuration and class-specific report-card mapping.
-- This migration is committed with the feature branch and is not applied to production automatically.
create table if not exists public.academic_sessions (
 id uuid primary key default gen_random_uuid(),
 school_code text not null default 'ashiana' check (school_code='ashiana'),
 label text not null check (label ~ '^[0-9]{4}-[0-9]{2}$'),
 starts_on date not null, ends_on date not null,
 is_active boolean not null default false, created_by text,
 created_at timestamptz not null default now(),
 check (ends_on>=starts_on), unique(school_code,label)
);
create unique index if not exists academic_sessions_one_active_per_school on public.academic_sessions(school_code) where is_active;
create table if not exists public.school_subjects (
 id uuid primary key default gen_random_uuid(),
 school_code text not null default 'ashiana' check (school_code='ashiana'),
 subject_code text not null check(length(trim(subject_code)) between 1 and 20),
 subject_name text not null check(length(trim(subject_name)) between 1 and 80),
 active boolean not null default true, created_at timestamptz not null default now(),
 unique(school_code,subject_code), unique(school_code,subject_name)
);
create table if not exists public.school_exams (
 id uuid primary key default gen_random_uuid(),
 school_code text not null default 'ashiana' check (school_code='ashiana'),
 academic_session_id uuid not null references public.academic_sessions(id) on delete restrict,
 exam_name text not null check(length(trim(exam_name)) between 1 and 100),
 exam_type text not null default 'Term' check(exam_type in ('Unit Test','Term','Half-Yearly','Annual','Other')),
 starts_on date, ends_on date,
 status text not null default 'Draft' check(status in ('Draft','Active','Completed')),
 created_by text, created_at timestamptz not null default now(),
 check(starts_on is null or ends_on is null or ends_on>=starts_on),
 unique(school_code,academic_session_id,exam_name)
);
create table if not exists public.exam_class_subjects (
 id uuid primary key default gen_random_uuid(),
 school_code text not null default 'ashiana' check (school_code='ashiana'),
 exam_id uuid not null references public.school_exams(id) on delete cascade,
 academic_session_id uuid not null references public.academic_sessions(id) on delete restrict,
 class_name text not null check(length(trim(class_name)) between 1 and 40),
 section text not null check(length(trim(section)) between 1 and 20),
 subject_id uuid not null references public.school_subjects(id) on delete restrict,
 teacher_email text, class_teacher_email text, max_marks numeric(7,2) not null check(max_marks>0 and max_marks<=1000),
 report_card_format text not null default 'class_specific' check(report_card_format in ('class_specific','class_iii_iv_result_cum_marksheet','existing')),
 assessment_config jsonb not null default '[]'::jsonb check(jsonb_typeof(assessment_config)='array'),
 active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(exam_id,class_name,section,subject_id)
);
-- Keep this migration safe if the table was created by an earlier partial rollout.
alter table public.exam_class_subjects add column if not exists class_teacher_email text;
create index if not exists exam_class_subjects_teacher_lookup on public.exam_class_subjects(school_code,lower(teacher_email),class_name,section) where active;
create index if not exists school_exams_session_lookup on public.school_exams(school_code,academic_session_id,status);
alter table public.academic_sessions enable row level security;
alter table public.school_subjects enable row level security;
alter table public.school_exams enable row level security;
alter table public.exam_class_subjects enable row level security;
drop policy if exists academic_sessions_admin_all on public.academic_sessions;
create policy academic_sessions_admin_all on public.academic_sessions for all to authenticated using(private.is_admin() and school_code='ashiana') with check(private.is_admin() and school_code='ashiana');
drop policy if exists academic_sessions_teacher_select on public.academic_sessions;
create policy academic_sessions_teacher_select on public.academic_sessions for select to authenticated using(school_code='ashiana' and exists(select 1 from public.school_exams e join public.exam_class_subjects ecs on ecs.exam_id=e.id where e.academic_session_id=academic_sessions.id and ecs.active and (exists(select 1 from public.student_class_assignments a where a.school_code=ecs.school_code and a.class_name=ecs.class_name and a.section=ecs.section and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and a.active) or lower(coalesce(ecs.teacher_email,''))=lower(coalesce(auth.jwt()->>'email','')) or lower(coalesce(ecs.class_teacher_email,''))=lower(coalesce(auth.jwt()->>'email','')) or exists(select 1 from public.student_subject_assignments sa where sa.school_code=ecs.school_code and sa.class_name=ecs.class_name and sa.section=ecs.section and lower(sa.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and sa.active))));
drop policy if exists school_subjects_admin_all on public.school_subjects;
create policy school_subjects_admin_all on public.school_subjects for all to authenticated using(private.is_admin() and school_code='ashiana') with check(private.is_admin() and school_code='ashiana');
drop policy if exists school_subjects_teacher_select on public.school_subjects;
create policy school_subjects_teacher_select on public.school_subjects for select to authenticated using(school_code='ashiana' and exists(select 1 from public.exam_class_subjects ecs where ecs.subject_id=school_subjects.id and ecs.active and (exists(select 1 from public.student_class_assignments a where a.school_code=ecs.school_code and a.class_name=ecs.class_name and a.section=ecs.section and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and a.active) or lower(coalesce(ecs.teacher_email,''))=lower(coalesce(auth.jwt()->>'email','')) or lower(coalesce(ecs.class_teacher_email,''))=lower(coalesce(auth.jwt()->>'email','')) or exists(select 1 from public.student_subject_assignments sa where sa.school_code=ecs.school_code and sa.class_name=ecs.class_name and sa.section=ecs.section and lower(sa.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and sa.active))));
drop policy if exists school_exams_admin_all on public.school_exams;
create policy school_exams_admin_all on public.school_exams for all to authenticated using(private.is_admin() and school_code='ashiana') with check(private.is_admin() and school_code='ashiana');
drop policy if exists school_exams_teacher_select on public.school_exams;
create policy school_exams_teacher_select on public.school_exams for select to authenticated using(school_code='ashiana' and exists(select 1 from public.exam_class_subjects ecs where ecs.exam_id=school_exams.id and ecs.active and (exists(select 1 from public.student_class_assignments a where a.school_code=ecs.school_code and a.class_name=ecs.class_name and a.section=ecs.section and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and a.active) or lower(coalesce(ecs.teacher_email,''))=lower(coalesce(auth.jwt()->>'email','')) or lower(coalesce(ecs.class_teacher_email,''))=lower(coalesce(auth.jwt()->>'email','')) or exists(select 1 from public.student_subject_assignments sa where sa.school_code=ecs.school_code and sa.class_name=ecs.class_name and sa.section=ecs.section and lower(sa.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and sa.active))));
drop policy if exists exam_class_subjects_admin_all on public.exam_class_subjects;
create policy exam_class_subjects_admin_all on public.exam_class_subjects for all to authenticated using(private.is_admin() and school_code='ashiana') with check(private.is_admin() and school_code='ashiana');
drop policy if exists exam_class_subjects_teacher_select on public.exam_class_subjects;
create policy exam_class_subjects_teacher_select on public.exam_class_subjects for select to authenticated using(school_code='ashiana' and (exists(select 1 from public.student_class_assignments a where a.school_code=exam_class_subjects.school_code and a.class_name=exam_class_subjects.class_name and a.section=exam_class_subjects.section and lower(a.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and a.active) or lower(coalesce(exam_class_subjects.teacher_email,''))=lower(coalesce(auth.jwt()->>'email','')) or lower(coalesce(exam_class_subjects.class_teacher_email,''))=lower(coalesce(auth.jwt()->>'email','')) or exists(select 1 from public.student_subject_assignments sa where sa.school_code=exam_class_subjects.school_code and sa.class_name=exam_class_subjects.class_name and sa.section=exam_class_subjects.section and lower(sa.teacher_email)=lower(coalesce(auth.jwt()->>'email','')) and sa.active)));

-- Persist the report-card layout choice without modifying existing report-card data.
alter table public.student_report_cards
  add column if not exists report_card_format text not null default 'standard'
  check (report_card_format in ('standard','result_cum_marksheet'));
