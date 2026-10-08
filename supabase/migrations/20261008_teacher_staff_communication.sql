-- Allow authenticated teachers/staff to start direct communication with selected active staff.
-- Keep the staff directory narrow: only communication-safe fields are returned.
create or replace function public.staff_communication_directory()
returns table(
  id text,
  name text,
  emp_id text,
  role text,
  department text
)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, s.name, s.emp_id, s.role, s.department
  from public.staff s
  where s.status='ACTIVE'
    and s.id <> coalesce((select private.current_staff_id()), '')
  order by s.name nulls last, s.emp_id nulls last
$$;

revoke all on function public.staff_communication_directory() from public, anon;
grant execute on function public.staff_communication_directory() to authenticated;

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
