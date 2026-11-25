-- Live updates for Parent–School Messages.
-- Student family messages continue to use the token-validated RPC polling
-- path in the client; this publication is for authenticated school staff views.
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
