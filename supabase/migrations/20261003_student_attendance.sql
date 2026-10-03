-- Student attendance foundation for EduPunch / Ashiana Attendance.
-- Roster is scoped by school_code; teachers can only access assigned class/sections.
create table if not exists public.student_roster (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  admission_no text,
  student_name text not null,
  class_name text not null,
  section text not null,
  roll_no text,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','INACTIVE')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (school_code, admission_no)
);
create index if not exists student_roster_class_idx
  on public.student_roster (school_code, class_name, section, status, student_name);

create table if not exists public.student_class_assignments (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  teacher_email text not null,
  class_name text not null,
  section text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_code, teacher_email, class_name, section)
);
create index if not exists student_class_assignments_teacher_idx
  on public.student_class_assignments (school_code, lower(teacher_email), active);

create table if not exists public.student_attendance (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  student_id uuid not null references public.student_roster(id) on delete cascade,
  attendance_date date not null default current_date,
  status text not null check (status in ('PRESENT','ABSENT','LEAVE')),
  marked_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique (school_code, student_id, attendance_date)
);
create index if not exists student_attendance_date_idx
  on public.student_attendance (school_code, attendance_date);

alter table public.student_roster enable row level security;
alter table public.student_class_assignments enable row level security;
alter table public.student_attendance enable row level security;

drop policy if exists student_roster_admin_all on public.student_roster;
create policy student_roster_admin_all on public.student_roster
for all to authenticated
using ((private.is_admin() and school_code = 'ashiana'))
with check ((private.is_admin() and school_code = 'ashiana'));

drop policy if exists student_roster_teacher_select on public.student_roster;
create policy student_roster_teacher_select on public.student_roster
for select to authenticated
using (
  exists (
    select 1 from public.student_class_assignments a
    where a.school_code = student_roster.school_code
      and lower(a.teacher_email) = lower(coalesce(auth.jwt() ->> 'email',''))
      and a.class_name = student_roster.class_name
      and a.section = student_roster.section
      and a.active = true
  )
);

drop policy if exists student_assignments_admin_all on public.student_class_assignments;
create policy student_assignments_admin_all on public.student_class_assignments
for all to authenticated
using ((private.is_admin() and school_code = 'ashiana'))
with check ((private.is_admin() and school_code = 'ashiana'));

drop policy if exists student_assignments_teacher_select on public.student_class_assignments;
create policy student_assignments_teacher_select on public.student_class_assignments
for select to authenticated
using (school_code = 'ashiana' and lower(teacher_email) = lower(coalesce(auth.jwt() ->> 'email','')));

drop policy if exists student_attendance_admin_all on public.student_attendance;
create policy student_attendance_admin_all on public.student_attendance
for all to authenticated
using ((private.is_admin() and school_code = 'ashiana'))
with check ((private.is_admin() and school_code = 'ashiana'));

drop policy if exists student_attendance_teacher_select on public.student_attendance;
create policy student_attendance_teacher_select on public.student_attendance
for select to authenticated
using (
  exists (
    select 1
    from public.student_roster s
    join public.student_class_assignments a
      on a.school_code = s.school_code
     and a.class_name = s.class_name
     and a.section = s.section
    where s.id = student_attendance.student_id
      and s.school_code = student_attendance.school_code
      and lower(a.teacher_email) = lower(coalesce(auth.jwt() ->> 'email',''))
      and a.active = true
  )
);

drop policy if exists student_attendance_teacher_insert on public.student_attendance;
create policy student_attendance_teacher_insert on public.student_attendance
for insert to authenticated
with check (
  marked_by = auth.uid()
  and exists (
    select 1
    from public.student_roster s
    join public.student_class_assignments a
      on a.school_code = s.school_code
     and a.class_name = s.class_name
     and a.section = s.section
    where s.id = student_attendance.student_id
      and s.school_code = student_attendance.school_code
      and lower(a.teacher_email) = lower(coalesce(auth.jwt() ->> 'email',''))
      and a.active = true
  )
);

drop policy if exists student_attendance_teacher_update on public.student_attendance;
create policy student_attendance_teacher_update on public.student_attendance
for update to authenticated
using (
  exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a
      on a.school_code = s.school_code
     and a.class_name = s.class_name
     and a.section = s.section
    where s.id = student_attendance.student_id
      and s.school_code = student_attendance.school_code
      and lower(a.teacher_email) = lower(coalesce(auth.jwt() ->> 'email',''))
      and a.active = true
  )
)
with check (
  marked_by = auth.uid()
  and exists (
    select 1 from public.student_roster s
    join public.student_class_assignments a
      on a.school_code = s.school_code
     and a.class_name = s.class_name
     and a.section = s.section
    where s.id = student_attendance.student_id
      and s.school_code = student_attendance.school_code
      and lower(a.teacher_email) = lower(coalesce(auth.jwt() ->> 'email',''))
      and a.active = true
  )
);

-- Expose only to authenticated sessions; RLS policies above enforce row-level authorization.
grant select, insert, update, delete on public.student_roster to authenticated;
grant select, insert, update, delete on public.student_class_assignments to authenticated;
grant select, insert, update, delete on public.student_attendance to authenticated;
