-- Extend the existing privacy-safe activity log to support active-user monitoring
-- across students, staff/teachers, and administrators. No existing data is deleted.
alter table public.student_activity_monitor
  add column if not exists role text not null default 'student',
  add column if not exists user_identifier text,
  add column if not exists user_name text;

update public.student_activity_monitor
set user_identifier = enroll_no
where user_identifier is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'student_activity_monitor_role_check'
      and conrelid = 'public.student_activity_monitor'::regclass
  ) then
    alter table public.student_activity_monitor
      add constraint student_activity_monitor_role_check
      check (role in ('student', 'staff', 'admin'));
  end if;
end $$;

create index if not exists student_activity_monitor_identity_idx
  on public.student_activity_monitor (school_code, role, user_identifier, created_at desc);
