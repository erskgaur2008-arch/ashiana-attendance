-- Role and module permission management for Ashiana Attendance.
-- Admin-managed permissions are stored separately from existing per-user fee approver grants.
begin;

create table if not exists public.role_module_permissions (
  role_key text not null check (role_key in ('ADMIN','PRINCIPAL','TEACHER','STAFF','STUDENT')),
  module_key text not null check (module_key ~ '^[a-z][a-z0-9_]{1,63}$'),
  can_view boolean not null default false,
  can_create boolean not null default false,
  can_edit boolean not null default false,
  can_delete boolean not null default false,
  can_approve boolean not null default false,
  can_manage boolean not null default false,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (role_key,module_key)
);

create table if not exists public.role_module_permission_audit (
  id bigint generated always as identity primary key,
  role_key text not null,
  module_key text not null,
  old_permissions jsonb,
  new_permissions jsonb not null,
  changed_by uuid not null references auth.users(id),
  changed_at timestamptz not null default now()
);

alter table public.role_module_permissions enable row level security;
alter table public.role_module_permission_audit enable row level security;
revoke all on public.role_module_permissions, public.role_module_permission_audit from public, anon, authenticated;
grant all on public.role_module_permissions, public.role_module_permission_audit to service_role;

create or replace function private.current_app_role()
returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when (select private.is_admin()) then 'ADMIN'
    else coalesce((
      select case
        when upper(trim(coalesce(s.role,''))) like '%PRINCIPAL%' then 'PRINCIPAL'
        when upper(trim(coalesce(s.role,''))) like '%TEACHER%' then 'TEACHER'
        else 'STAFF'
      end
      from public.staff s
      where s.id=(select private.current_staff_id()) and s.status='ACTIVE'
      limit 1
    ), 'UNKNOWN')
  end;
$$;
revoke all on function private.current_app_role() from public, anon;
grant execute on function private.current_app_role() to authenticated;

create or replace function public.check_role_module_permission(
  p_module_key text, p_permission text
) returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare v_role text; v_allowed boolean;
begin
  if auth.uid() is null then return false; end if;
  v_role := private.current_app_role();
  if v_role='ADMIN' then return true; end if;
  if v_role not in ('PRINCIPAL','TEACHER','STAFF','STUDENT') then return false; end if;
  select case p_permission
    when 'view' then can_view
    when 'create' then can_create
    when 'edit' then can_edit
    when 'delete' then can_delete
    when 'approve' then can_approve
    when 'manage' then can_manage
    else false
  end into v_allowed
  from public.role_module_permissions
  where role_key=v_role and module_key=p_module_key;
  return coalesce(v_allowed,false);
end;
$$;
revoke all on function public.check_role_module_permission(text,text) from public, anon;
grant execute on function public.check_role_module_permission(text,text) to authenticated;

create or replace function public.admin_list_role_module_permissions()
returns table (
  role_key text, module_key text, can_view boolean, can_create boolean,
  can_edit boolean, can_delete boolean, can_approve boolean, can_manage boolean,
  updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Administrator permission required';
  end if;
  return query
  select p.role_key,p.module_key,p.can_view,p.can_create,p.can_edit,
         p.can_delete,p.can_approve,p.can_manage,p.updated_at
  from public.role_module_permissions p
  order by p.role_key,p.module_key;
end;
$$;

create or replace function public.admin_set_role_module_permission(
  p_role_key text, p_module_key text,
  p_can_view boolean, p_can_create boolean, p_can_edit boolean,
  p_can_delete boolean, p_can_approve boolean, p_can_manage boolean
) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_old jsonb;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Administrator permission required';
  end if;
  if p_role_key not in ('PRINCIPAL','TEACHER','STAFF','STUDENT') then
    raise exception 'Only non-administrator role permissions can be edited';
  end if;
  if p_module_key !~ '^[a-z][a-z0-9_]{1,63}$' then
    raise exception 'Invalid module key';
  end if;
  select jsonb_build_object(
    'can_view',can_view,'can_create',can_create,'can_edit',can_edit,
    'can_delete',can_delete,'can_approve',can_approve,'can_manage',can_manage
  ) into v_old
  from public.role_module_permissions
  where role_key=p_role_key and module_key=p_module_key;

  insert into public.role_module_permissions(
    role_key,module_key,can_view,can_create,can_edit,can_delete,can_approve,can_manage,updated_by,updated_at
  ) values (
    p_role_key,p_module_key,coalesce(p_can_view,false),coalesce(p_can_create,false),
    coalesce(p_can_edit,false),coalesce(p_can_delete,false),coalesce(p_can_approve,false),
    coalesce(p_can_manage,false),auth.uid(),now()
  )
  on conflict (role_key,module_key) do update set
    can_view=excluded.can_view,can_create=excluded.can_create,can_edit=excluded.can_edit,
    can_delete=excluded.can_delete,can_approve=excluded.can_approve,can_manage=excluded.can_manage,
    updated_by=auth.uid(),updated_at=now();

  insert into public.role_module_permission_audit(role_key,module_key,old_permissions,new_permissions,changed_by)
  values (
    p_role_key,p_module_key,v_old,
    jsonb_build_object(
      'can_view',coalesce(p_can_view,false),'can_create',coalesce(p_can_create,false),
      'can_edit',coalesce(p_can_edit,false),'can_delete',coalesce(p_can_delete,false),
      'can_approve',coalesce(p_can_approve,false),'can_manage',coalesce(p_can_manage,false)
    ),auth.uid()
  );
end;
$$;

revoke all on function public.admin_list_role_module_permissions() from public, anon;
revoke all on function public.admin_set_role_module_permission(text,text,boolean,boolean,boolean,boolean,boolean,boolean) from public, anon;
grant execute on function public.admin_list_role_module_permissions() to authenticated;
grant execute on function public.admin_set_role_module_permission(text,text,boolean,boolean,boolean,boolean,boolean,boolean) to authenticated;

-- Seed module rows only; existing feature-specific authorization remains authoritative.
insert into public.role_module_permissions(role_key,module_key,can_view,can_create,can_edit,can_delete,can_approve,can_manage)
select r.role_key,m.module_key,
       (r.role_key='PRINCIPAL' and m.module_key in ('attendance','leaves','student_portal','communication','corrections','live_location','fee_confirmations'))
       or (r.role_key='TEACHER' and m.module_key in ('attendance','leaves','student_portal','communication'))
       or (r.role_key='STAFF' and m.module_key in ('attendance','leaves','communication'))
       or (r.role_key='STUDENT' and m.module_key in ('student_portal')),
       (r.role_key='TEACHER' and m.module_key in ('attendance','leaves','communication'))
       or (r.role_key='STAFF' and m.module_key in ('leaves','communication')),
       false,false,
       (r.role_key='PRINCIPAL' and m.module_key='fee_confirmations'),
       false
from (values ('PRINCIPAL'),('TEACHER'),('STAFF'),('STUDENT')) r(role_key)
cross join (values
 ('attendance'),('leaves'),('student_portal'),('communication'),('corrections'),
 ('live_location'),('fee_confirmations'),('fees'),('settings'),('role_management'),('security')
) m(module_key)
on conflict (role_key,module_key) do nothing;

notify pgrst, 'reload schema';
commit;
