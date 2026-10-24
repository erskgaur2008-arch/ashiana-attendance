-- Allow teachers/staff to add selected active recipients to their own direct threads.
-- Admins retain their existing multi-recipient permissions.
drop policy if exists staff_comm_recipients_insert on public.staff_communication_recipients;
create policy staff_comm_recipients_insert
on public.staff_communication_recipients
for insert to authenticated
with check (
  exists (
    select 1
    from public.staff_communication_threads t
    where t.id=thread_id
      and lower(t.created_by_email)=lower(coalesce(auth.jwt()->>'email',''))
      and (
        (select private.is_admin())
        or (
          t.created_by_role in ('TEACHER','STAFF')
          and t.audience='DIRECT'
          and (select private.current_staff_id()) is not null
        )
      )
  )
  and exists (
    select 1
    from public.staff s
    where s.id=staff_id
      and s.status='ACTIVE'
  )
);
notify pgrst, 'reload schema';
