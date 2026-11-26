-- Administrator-assigned staff tasks with immutable progress history.
-- Applying this migration adds task data structures only; existing school data is unchanged.

create table if not exists public.teacher_tasks (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana' check (school_code = 'ashiana'),
  assigned_to_staff_id text references public.staff(id) on delete set null,
  assigned_to_email text not null,
  assigned_to_name text not null,
  title text not null check (char_length(btrim(title)) between 1 and 180),
  description text not null default '' check (char_length(description) <= 4000),
  due_date date not null,
  created_by_email text not null,
  created_by_name text not null default 'Administrator',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists teacher_tasks_assignee_due_idx
  on public.teacher_tasks (lower(assigned_to_email), due_date, created_at desc);

create table if not exists public.teacher_task_progress_updates (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.teacher_tasks(id) on delete cascade,
  school_code text not null default 'ashiana' check (school_code = 'ashiana'),
  progress_percent smallint not null check (progress_percent between 0 and 100),
  status text not null check (status in ('NOT_STARTED','IN_PROGRESS','BLOCKED','COMPLETED')),
  note text not null default '' check (char_length(note) <= 2000),
  updated_by_email text not null,
  updated_by_name text not null,
  created_at timestamptz not null default now(),
  check (status <> 'COMPLETED' or progress_percent = 100),
  check (status <> 'NOT_STARTED' or progress_percent = 0)
);

create index if not exists teacher_task_progress_updates_recent_idx
  on public.teacher_task_progress_updates (task_id, created_at desc);

-- Add the staff task page to the existing administrator-managed role settings.
alter table public.role_portal_module_permissions
  drop constraint if exists role_portal_module_permissions_module_key_check;
alter table public.role_portal_module_permissions
  add constraint role_portal_module_permissions_module_key_check
  check (module_key in (
    'punch', 'history', 'students', 'communication', 'leave', 'profile', 'biometric',
    'mentor', 'classmates', 'notice', 'attendance', 'report-card', 'fees', 'homework',
    'timetable', 'calendar', 'id-card', 'event-photos', 'messages', 'tasks'
  ));
insert into public.role_portal_module_permissions (role, module_key, enabled)
values ('TEACHER', 'tasks', true), ('STAFF', 'tasks', true)
on conflict (role, module_key) do nothing;

alter table public.teacher_tasks enable row level security;
alter table public.teacher_task_progress_updates enable row level security;

revoke all on table public.teacher_tasks from public, anon;
revoke all on table public.teacher_task_progress_updates from public, anon;
grant select, insert, update, delete on table public.teacher_tasks to authenticated;
grant select, insert on table public.teacher_task_progress_updates to authenticated;

drop policy if exists teacher_tasks_admin_manage on public.teacher_tasks;
create policy teacher_tasks_admin_manage on public.teacher_tasks
for all to authenticated
using (private.is_admin() and school_code = 'ashiana')
with check (private.is_admin() and school_code = 'ashiana');

drop policy if exists teacher_tasks_assignee_read on public.teacher_tasks;
create policy teacher_tasks_assignee_read on public.teacher_tasks
for select to authenticated
using (
  school_code = 'ashiana'
  and lower(assigned_to_email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
);

drop policy if exists teacher_task_progress_updates_admin_read on public.teacher_task_progress_updates;
create policy teacher_task_progress_updates_admin_read on public.teacher_task_progress_updates
for select to authenticated
using (private.is_admin() and school_code = 'ashiana');

drop policy if exists teacher_task_progress_updates_assignee_read on public.teacher_task_progress_updates;
create policy teacher_task_progress_updates_assignee_read on public.teacher_task_progress_updates
for select to authenticated
using (
  school_code = 'ashiana'
  and exists (
    select 1
    from public.teacher_tasks t
    where t.id = teacher_task_progress_updates.task_id
      and t.school_code = teacher_task_progress_updates.school_code
      and lower(t.assigned_to_email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  )
);

drop policy if exists teacher_task_progress_updates_assignee_insert on public.teacher_task_progress_updates;
create policy teacher_task_progress_updates_assignee_insert on public.teacher_task_progress_updates
for insert to authenticated
with check (
  school_code = 'ashiana'
  and lower(updated_by_email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  and exists (
    select 1
    from public.teacher_tasks t
    where t.id = teacher_task_progress_updates.task_id
      and t.school_code = teacher_task_progress_updates.school_code
      and lower(t.assigned_to_email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  )
);

create or replace function private.teacher_tasks_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

drop trigger if exists teacher_tasks_set_updated_at on public.teacher_tasks;
create trigger teacher_tasks_set_updated_at
before update on public.teacher_tasks
for each row execute function private.teacher_tasks_set_updated_at();

-- Live task boards subscribe to these two tables through Supabase Realtime.
do $publication$
declare
  v_table text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise exception 'Expected Supabase publication supabase_realtime was not found';
  end if;

  foreach v_table in array array['teacher_tasks', 'teacher_task_progress_updates'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = v_table
    ) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end;
$publication$;

notify pgrst, 'reload schema';
