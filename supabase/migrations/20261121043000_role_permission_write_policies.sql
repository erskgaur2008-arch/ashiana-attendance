drop policy if exists role_portal_module_permissions_admin_write
  on public.role_portal_module_permissions;

create policy role_portal_module_permissions_admin_insert
  on public.role_portal_module_permissions
  for insert
  to authenticated
  with check ((select private.is_admin()));

create policy role_portal_module_permissions_admin_update
  on public.role_portal_module_permissions
  for update
  to authenticated
  using ((select private.is_admin()))
  with check ((select private.is_admin()));

create policy role_portal_module_permissions_admin_delete
  on public.role_portal_module_permissions
  for delete
  to authenticated
  using ((select private.is_admin()));
