-- Admin communication: allow one thread to target multiple staff members.
create table if not exists public.staff_communication_recipients (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.staff_communication_threads(id) on delete cascade,
  staff_id text not null references public.staff(id) on update cascade on delete cascade,
  created_at timestamptz not null default now(),
  unique(thread_id, staff_id)
);

create index if not exists staff_comm_recipients_thread_idx
  on public.staff_communication_recipients(thread_id);
create index if not exists staff_comm_recipients_staff_idx
  on public.staff_communication_recipients(staff_id);

alter table public.staff_communication_recipients enable row level security;
revoke all on public.staff_communication_recipients from anon, authenticated;
grant select, insert, delete on public.staff_communication_recipients to authenticated;
grant all on public.staff_communication_recipients to service_role;

drop policy if exists staff_comm_recipients_select on public.staff_communication_recipients;
create policy staff_comm_recipients_select
on public.staff_communication_recipients
for select to authenticated
using (
  (select private.is_admin())
  or staff_id=(select private.current_staff_id())
);

drop policy if exists staff_comm_recipients_insert on public.staff_communication_recipients;
create policy staff_comm_recipients_insert
on public.staff_communication_recipients
for insert to authenticated
with check (
  (select private.is_admin())
  and exists (
    select 1
    from public.staff_communication_threads t
    where t.id=thread_id
      and lower(t.created_by_email)=lower(coalesce(auth.jwt()->>'email',''))
      and t.created_by_role='ADMIN'
  )
);

drop policy if exists staff_comm_recipients_delete on public.staff_communication_recipients;
create policy staff_comm_recipients_delete
on public.staff_communication_recipients
for delete to authenticated
using ((select private.is_admin()));

create or replace function private.can_access_staff_communication_thread(p_thread_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
 select (select private.is_admin()) or exists (
   select 1
   from public.staff_communication_threads t
   left join public.staff s on s.id=t.recipient_staff_id
   where t.id=p_thread_id
     and (
       lower(t.created_by_email)=lower(coalesce(auth.jwt()->>'email',''))
       or lower(coalesce(s.email,''))=lower(coalesce(auth.jwt()->>'email',''))
       or exists (
         select 1
         from public.staff_communication_recipients r
         where r.thread_id=t.id
           and r.staff_id=(select private.current_staff_id())
       )
       or (
         t.audience='ALL_STAFF'
         and exists(
           select 1
           from public.staff me
           where me.id=(select private.current_staff_id())
             and me.status='ACTIVE'
         )
       )
     )
 )
$$;

revoke all on function private.can_access_staff_communication_thread(uuid) from public, anon;
grant execute on function private.can_access_staff_communication_thread(uuid) to authenticated;

notify pgrst, 'reload schema';
