-- Replace legacy global authorization policies with tenant-membership policies.
-- Depends on tenant columns/backfill and integrity migration; staged only.
begin;

create schema if not exists private;

create or replace function private.has_active_tenant_role(p_tenant_id uuid, p_role text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.tenant_memberships m
    join public.tenants t on t.id = m.tenant_id
    where m.user_id = (select auth.uid())
      and m.tenant_id = p_tenant_id
      and m.role = p_role
      and m.active = true
      and t.status = 'active'
  );
$function$;

create or replace function private.current_staff_tenant_id()
returns uuid
language sql
stable
security definer
set search_path to ''
as $function$
  select s.tenant_id
  from public.staff s
  where lower(s.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
    and s.status = 'ACTIVE'
  limit 1;
$function$;

revoke all on function private.has_active_tenant_role(uuid,text) from public, anon;
revoke all on function private.current_staff_tenant_id() from public, anon;
grant execute on function private.has_active_tenant_role(uuid,text) to authenticated, service_role;
grant execute on function private.current_staff_tenant_id() to authenticated, service_role;

-- admin_users
drop policy if exists admin_self_select on public.admin_users;
create policy admin_self_select on public.admin_users
for select to authenticated
using (
  lower(email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  and active = true
  and private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN')
);

-- staff
drop policy if exists admin_staff_delete on public.staff;
drop policy if exists admin_staff_insert on public.staff;
drop policy if exists admin_staff_update on public.staff;
drop policy if exists staff_self_or_admin_select on public.staff;
drop policy if exists staff_self_update on public.staff;
create policy tenant_admin_staff_select on public.staff
for select to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));
create policy tenant_staff_self_select on public.staff
for select to authenticated
using (
  lower(email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  and tenant_id = (select private.current_staff_tenant_id())
);
create policy tenant_admin_staff_insert on public.staff
for insert to authenticated
with check (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));
create policy tenant_admin_staff_update on public.staff
for update to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'))
with check (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));
create policy tenant_admin_staff_delete on public.staff
for delete to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));
create policy tenant_staff_self_update on public.staff
for update to authenticated
using (
  lower(email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  and tenant_id = (select private.current_staff_tenant_id())
)
with check (
  lower(email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  and tenant_id = (select private.current_staff_tenant_id())
);

-- attendance punches
drop policy if exists admin_attendance_insert on public.attendance_punches;
drop policy if exists attendance_self_or_admin_select on public.attendance_punches;
create policy tenant_attendance_select on public.attendance_punches
for select to authenticated
using (
  private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN')
  or exists (
    select 1 from public.staff s
    where s.id = attendance_punches.staff_id
      and s.tenant_id = attendance_punches.tenant_id
      and lower(s.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
      and s.status = 'ACTIVE'
  )
);
create policy tenant_attendance_admin_insert on public.attendance_punches
for insert to authenticated
with check (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));

-- leave requests
drop policy if exists leave_admin_update on public.leave_requests;
drop policy if exists leave_self_insert on public.leave_requests;
drop policy if exists leave_self_select on public.leave_requests;
create policy tenant_leave_select on public.leave_requests
for select to authenticated
using (
  private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN')
  or exists (
    select 1 from public.staff s
    where s.id = leave_requests.staff_id
      and s.tenant_id = leave_requests.tenant_id
      and lower(s.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  )
);
create policy tenant_leave_insert on public.leave_requests
for insert to authenticated
with check (
  exists (
    select 1 from public.staff s
    where s.id = leave_requests.staff_id
      and s.tenant_id = leave_requests.tenant_id
      and lower(s.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
      and s.status = 'ACTIVE'
  )
  and private.has_active_tenant_role(tenant_id, 'STAFF')
);
create policy tenant_leave_admin_update on public.leave_requests
for update to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'))
with check (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));

-- Audit log and QR sessions are school-admin readable/writable only through
-- these policies; service-role Edge Functions bypass RLS as intended.
drop policy if exists audit_admin_insert on public.audit_logs;
drop policy if exists audit_admin_select on public.audit_logs;
create policy tenant_audit_insert on public.audit_logs
for insert to authenticated
with check (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));
create policy tenant_audit_select on public.audit_logs
for select to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));

drop policy if exists qr_admin_select on public.attendance_qr_sessions;
create policy tenant_qr_admin_select on public.attendance_qr_sessions
for select to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));

-- Staff ID cards
drop policy if exists admin_staff_id_cards_insert on public.staff_id_cards;
drop policy if exists admin_staff_id_cards_select on public.staff_id_cards;
drop policy if exists admin_staff_id_cards_update on public.staff_id_cards;
drop policy if exists staff_own_id_card_select on public.staff_id_cards;
create policy tenant_id_cards_admin_select on public.staff_id_cards
for select to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));
create policy tenant_id_cards_self_select on public.staff_id_cards
for select to authenticated
using (
  tenant_id = (select private.current_staff_tenant_id())
  and exists (
    select 1 from public.staff s
    where s.id = staff_id_cards.staff_id
      and s.tenant_id = staff_id_cards.tenant_id
      and lower(s.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
  )
);
create policy tenant_id_cards_admin_insert on public.staff_id_cards
for insert to authenticated
with check (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));
create policy tenant_id_cards_admin_update on public.staff_id_cards
for update to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'))
with check (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));
create policy tenant_id_cards_admin_delete on public.staff_id_cards
for delete to authenticated
using (private.has_active_tenant_role(tenant_id, 'SCHOOL_ADMIN'));

commit;
