alter table public.role_portal_module_permissions
  drop constraint if exists role_portal_module_permissions_module_key_check;

alter table public.role_portal_module_permissions
  add constraint role_portal_module_permissions_module_key_check
  check (module_key in (
    'punch', 'history', 'students', 'communication', 'leave', 'profile', 'biometric',
    'mentor', 'classmates', 'notice', 'attendance', 'report-card', 'fees', 'homework',
    'timetable', 'calendar', 'id-card', 'event-photos'
  ));

insert into public.role_portal_module_permissions (role, module_key, enabled)
values ('STUDENT', 'event-photos', true)
on conflict (role, module_key) do nothing;
