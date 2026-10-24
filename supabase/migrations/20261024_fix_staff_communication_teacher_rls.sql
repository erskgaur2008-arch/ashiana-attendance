-- Fix teacher/staff communication creation when a recipient is selected.
-- The previous policy required recipient_staff_id IS NULL, but the composer
-- sets recipient_staff_id for a single selected recipient.
drop policy if exists staff_comm_threads_insert on public.staff_communication_threads;
create policy staff_comm_threads_insert
on public.staff_communication_threads
for insert to authenticated
with check (
  (select private.is_admin())
  or (
    (select private.current_staff_id()) is not null
    and lower(created_by_email)=lower(coalesce(auth.jwt()->>'email',''))
    and created_by_role in ('TEACHER','STAFF')
    and audience='DIRECT'
    and (
      recipient_staff_id is null
      or exists (
        select 1
        from public.staff recipient
        where recipient.id=recipient_staff_id
          and recipient.status='ACTIVE'
      )
    )
  )
);
notify pgrst, 'reload schema';
