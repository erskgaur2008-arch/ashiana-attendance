-- Make staff avatars private and authorize access by active school membership.
-- Depends on tenant foundation and private.has_active_tenant_role from 06000.
-- Existing public URL strings remain in staff.avatar_url for compatibility; the
-- frontend converts their known Storage URL suffix to an object path before signing.
-- Staged only: apply only after branch frontend is deployed and legacy objects verified.
begin;

update storage.buckets
set public = false
where id = 'staff-avatars';

drop policy if exists staff_avatar_public_read on storage.objects;
drop policy if exists staff_avatar_authenticated_insert on storage.objects;
drop policy if exists staff_avatar_authenticated_update on storage.objects;
drop policy if exists staff_avatar_authenticated_delete on storage.objects;

-- Active staff and school administrators may read avatars in their own active
-- tenant. New objects use {tenant_uuid}/{auth_user_uuid}/...; legacy objects
-- remain under {auth_user_uuid}/... and are authorized through staff.avatar_url.
create policy staff_avatar_tenant_member_read
on storage.objects for select to authenticated
using (
  bucket_id = 'staff-avatars'
  and (
    private.has_active_tenant_role(
      (select t.id from public.tenants t
       where t.id::text = (storage.foldername(name))[1]
         and t.status = 'active'
       limit 1),
      'STAFF'
    )
    or private.has_active_tenant_role(
      (select t.id from public.tenants t
       where t.id::text = (storage.foldername(name))[1]
         and t.status = 'active'
       limit 1),
      'SCHOOL_ADMIN'
    )
    or exists (
      select 1
      from public.staff s
      where s.avatar_url is not null
        and right(s.avatar_url, length(name)) = name
        and (
          private.has_active_tenant_role(s.tenant_id, 'STAFF')
          or private.has_active_tenant_role(s.tenant_id, 'SCHOOL_ADMIN')
        )
    )
  )
);

-- A staff member may upload only to their own Auth-UID folder inside their
-- active tenant. The staff row binds that identity to the same tenant.
create policy staff_avatar_tenant_member_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'staff-avatars'
  and (storage.foldername(name))[2] = (select auth.uid())::text
  and exists (
    select 1
    from public.tenants t
    join public.staff s on s.tenant_id = t.id
    where t.id::text = (storage.foldername(name))[1]
      and t.status = 'active'
      and s.status = 'ACTIVE'
      and lower(s.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
      and private.has_active_tenant_role(t.id, 'STAFF')
  )
);

-- Allow authenticated staff to replace/delete only objects in their own new
-- tenant-prefixed path. Legacy user-first objects are not writable via this
-- policy; users can upload a new private copy instead.
create policy staff_avatar_tenant_member_update
on storage.objects for update to authenticated
using (
  bucket_id = 'staff-avatars'
  and (storage.foldername(name))[2] = (select auth.uid())::text
  and exists (
    select 1 from public.tenants t
    where t.id::text = (storage.foldername(name))[1]
      and t.status = 'active'
      and private.has_active_tenant_role(t.id, 'STAFF')
  )
)
with check (
  bucket_id = 'staff-avatars'
  and (storage.foldername(name))[2] = (select auth.uid())::text
  and exists (
    select 1 from public.tenants t
    where t.id::text = (storage.foldername(name))[1]
      and t.status = 'active'
      and private.has_active_tenant_role(t.id, 'STAFF')
  )
);

create policy staff_avatar_tenant_member_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'staff-avatars'
  and (
    ((storage.foldername(name))[2] = (select auth.uid())::text
      and exists (
        select 1 from public.tenants t
        where t.id::text = (storage.foldername(name))[1]
          and t.status = 'active'
          and private.has_active_tenant_role(t.id, 'STAFF')
      ))
    or
    ((storage.foldername(name))[1] = (select auth.uid())::text
      and exists (
        select 1 from public.staff s
        where s.avatar_url is not null
          and right(s.avatar_url, length(name)) = name
          and private.has_active_tenant_role(s.tenant_id, 'STAFF')
      ))
  )
);

commit;
