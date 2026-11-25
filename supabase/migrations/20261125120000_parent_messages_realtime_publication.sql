-- Live updates for Parent–School Messages.
-- Only authenticated school staff who can access a conversation may receive
-- its Realtime row events. Student family messages remain token-RPC based.
grant usage on schema private to authenticated;
grant select on public.parent_message_threads, public.parent_message_messages to authenticated;
grant execute on function private.parent_message_staff_can_access_thread(uuid) to authenticated;

drop policy if exists parent_message_threads_realtime_select on public.parent_message_threads;
create policy parent_message_threads_realtime_select
  on public.parent_message_threads
  for select
  to authenticated
  using (private.parent_message_staff_can_access_thread(id));

drop policy if exists parent_message_messages_realtime_select on public.parent_message_messages;
create policy parent_message_messages_realtime_select
  on public.parent_message_messages
  for select
  to authenticated
  using (private.parent_message_staff_can_access_thread(thread_id));

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'parent_message_threads'
  ) then
    alter publication supabase_realtime add table public.parent_message_threads;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'parent_message_messages'
  ) then
    alter publication supabase_realtime add table public.parent_message_messages;
  end if;
end
$$;
