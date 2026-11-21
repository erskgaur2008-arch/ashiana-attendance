-- Admin-managed visibility for portal pages/modules. These settings shape the
-- app navigation only; existing table RLS and RPC authorization remain the
-- authority for reading or changing school data.
create table if not exists public.role_portal_module_permissions (
  role text not null check (role in ('STAFF', 'TEACHER', 'STUDENT')),
  module_key text not null check (module_key in (
    'punch', 'history', 'students', 'communication', 'leave', 'profile', 'biometric',
    'mentor', 'classmates', 'notice', 'attendance', 'report-card', 'fees', 'homework',
    'timetable', 'calendar', 'id-card'
  )),
  enabled boolean not null default true,
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (role, module_key)
);

comment on table public.role_portal_module_permissions is
  'Admin-managed portal page visibility by role. Does not replace data-level RLS or RPC authorization.';

alter table public.role_portal_module_permissions enable row level security;
revoke all on table public.role_portal_module_permissions from public, anon;
grant select, insert, update, delete on table public.role_portal_module_permissions to authenticated;

drop policy if exists role_portal_module_permissions_read on public.role_portal_module_permissions;
create policy role_portal_module_permissions_read
  on public.role_portal_module_permissions
  for select to authenticated
  using (true);

drop policy if exists role_portal_module_permissions_admin_write on public.role_portal_module_permissions;
create policy role_portal_module_permissions_admin_write
  on public.role_portal_module_permissions
  for all to authenticated
  using ((select private.is_admin()))
  with check ((select private.is_admin()));

insert into public.role_portal_module_permissions (role, module_key, enabled) values
  ('STAFF', 'punch', true),
  ('STAFF', 'history', true),
  ('STAFF', 'students', false),
  ('STAFF', 'communication', true),
  ('STAFF', 'leave', true),
  ('STAFF', 'profile', true),
  ('STAFF', 'biometric', true),
  ('STAFF', 'fees', true),
  ('TEACHER', 'punch', true),
  ('TEACHER', 'history', true),
  ('TEACHER', 'students', true),
  ('TEACHER', 'communication', true),
  ('TEACHER', 'leave', true),
  ('TEACHER', 'profile', true),
  ('TEACHER', 'biometric', true),
  ('TEACHER', 'fees', true),
  ('STUDENT', 'profile', true),
  ('STUDENT', 'mentor', true),
  ('STUDENT', 'classmates', true),
  ('STUDENT', 'notice', true),
  ('STUDENT', 'attendance', true),
  ('STUDENT', 'report-card', true),
  ('STUDENT', 'fees', true),
  ('STUDENT', 'homework', true),
  ('STUDENT', 'timetable', true),
  ('STUDENT', 'leave', true),
  ('STUDENT', 'calendar', true),
  ('STUDENT', 'id-card', true)
on conflict (role, module_key) do nothing;

-- Student portal sessions use an opaque bearer token instead of Supabase Auth.
-- This RPC returns only the student's module visibility flags after validating
-- that token against the existing active student session table.
create or replace function public.student_role_portal_permissions(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_permissions jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select coalesce(jsonb_object_agg(p.module_key, p.enabled), '{}'::jsonb)
    into v_permissions
    from public.role_portal_module_permissions p
   where p.role = 'STUDENT';

  return jsonb_build_object('success', true, 'permissions', v_permissions);
end;
$function$;

revoke all on function public.student_role_portal_permissions(text) from public, anon, authenticated;
grant execute on function public.student_role_portal_permissions(text) to anon, authenticated;

notify pgrst, 'reload schema';
