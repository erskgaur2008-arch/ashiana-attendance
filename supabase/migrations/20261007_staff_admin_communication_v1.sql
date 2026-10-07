-- Staff ↔ Administration communication v1
create table if not exists public.staff_communication_threads (
 id uuid primary key default gen_random_uuid(), school_code text not null default 'ashiana',
 subject text not null check (length(trim(subject)) between 1 and 200),
 category text not null default 'GENERAL' check (category in ('GENERAL','REQUEST','ISSUE','SUGGESTION','STUDENT_CONCERN','ACADEMIC','IT','INFRASTRUCTURE','URGENT')),
 priority text not null default 'NORMAL' check (priority in ('NORMAL','IMPORTANT','URGENT')),
 status text not null default 'OPEN' check (status in ('OPEN','IN_PROGRESS','RESOLVED','CLOSED')),
 audience text not null default 'DIRECT' check (audience in ('DIRECT','ALL_STAFF')),
 created_by_email text not null, created_by_role text not null check (created_by_role in ('ADMIN','TEACHER','STAFF')),
 recipient_staff_id text references public.staff(id) on update cascade on delete set null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), last_message_at timestamptz not null default now()
);
create table if not exists public.staff_communication_messages (
 id uuid primary key default gen_random_uuid(), thread_id uuid not null references public.staff_communication_threads(id) on delete cascade,
 sender_email text not null, sender_role text not null check (sender_role in ('ADMIN','TEACHER','STAFF')),
 body text not null check (length(trim(body)) between 1 and 5000), created_at timestamptz not null default now()
);
create table if not exists public.staff_communication_reads (
 id uuid primary key default gen_random_uuid(), thread_id uuid not null references public.staff_communication_threads(id) on delete cascade,
 reader_email text not null, last_read_at timestamptz not null default now(), unique(thread_id, reader_email)
);
create index if not exists staff_comm_threads_recipient_idx on public.staff_communication_threads(recipient_staff_id);
create index if not exists staff_comm_threads_creator_idx on public.staff_communication_threads(lower(created_by_email));
create index if not exists staff_comm_threads_last_message_idx on public.staff_communication_threads(last_message_at desc);
create index if not exists staff_comm_messages_thread_idx on public.staff_communication_messages(thread_id, created_at);
create index if not exists staff_comm_reads_reader_idx on public.staff_communication_reads(lower(reader_email));

create or replace function private.current_staff_id() returns text language sql stable security definer set search_path = '' as $$
 select s.id from public.staff s where s.status='ACTIVE' and lower(s.email)=lower(coalesce(auth.jwt()->>'email','')) limit 1
$$;
revoke all on function private.current_staff_id() from public, anon;
grant execute on function private.current_staff_id() to authenticated;

create or replace function private.can_access_staff_communication_thread(p_thread_id uuid) returns boolean language sql stable security definer set search_path = '' as $$
 select (select private.is_admin()) or exists (
   select 1 from public.staff_communication_threads t left join public.staff s on s.id=t.recipient_staff_id
   where t.id=p_thread_id and (
     lower(t.created_by_email)=lower(coalesce(auth.jwt()->>'email',''))
     or lower(coalesce(s.email,''))=lower(coalesce(auth.jwt()->>'email',''))
     or (t.audience='ALL_STAFF' and exists(select 1 from public.staff me where me.id=(select private.current_staff_id()) and me.status='ACTIVE'))
   )
 )
$$;
revoke all on function private.can_access_staff_communication_thread(uuid) from public, anon;
grant execute on function private.can_access_staff_communication_thread(uuid) to authenticated;

create or replace function public.staff_communication_touch_thread() returns trigger language plpgsql security definer set search_path = '' as $$
begin update public.staff_communication_threads set updated_at=now(), last_message_at=new.created_at where id=new.thread_id; return new; end
$$;
revoke all on function public.staff_communication_touch_thread() from public, anon, authenticated;
drop trigger if exists trg_staff_communication_touch_thread on public.staff_communication_messages;
create trigger trg_staff_communication_touch_thread after insert on public.staff_communication_messages for each row execute function public.staff_communication_touch_thread();

alter table public.staff_communication_threads enable row level security;
alter table public.staff_communication_messages enable row level security;
alter table public.staff_communication_reads enable row level security;
revoke all on table public.staff_communication_threads, public.staff_communication_messages, public.staff_communication_reads from anon, authenticated;
grant select,insert,update on public.staff_communication_threads to authenticated;
grant select,insert on public.staff_communication_messages to authenticated;
grant select,insert,update on public.staff_communication_reads to authenticated;
grant all on public.staff_communication_threads, public.staff_communication_messages, public.staff_communication_reads to service_role;

drop policy if exists staff_comm_threads_select on public.staff_communication_threads;
create policy staff_comm_threads_select on public.staff_communication_threads for select to authenticated using ((select private.can_access_staff_communication_thread(id)));
drop policy if exists staff_comm_threads_insert on public.staff_communication_threads;
create policy staff_comm_threads_insert on public.staff_communication_threads for insert to authenticated with check (
 (select private.is_admin()) or ((select private.current_staff_id()) is not null and lower(created_by_email)=lower(coalesce(auth.jwt()->>'email','')) and created_by_role in ('TEACHER','STAFF') and audience='DIRECT' and recipient_staff_id is null)
);
drop policy if exists staff_comm_threads_update on public.staff_communication_threads;
create policy staff_comm_threads_update on public.staff_communication_threads for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));

drop policy if exists staff_comm_messages_select on public.staff_communication_messages;
create policy staff_comm_messages_select on public.staff_communication_messages for select to authenticated using ((select private.can_access_staff_communication_thread(thread_id)));
drop policy if exists staff_comm_messages_insert on public.staff_communication_messages;
create policy staff_comm_messages_insert on public.staff_communication_messages for insert to authenticated with check (
 (select private.can_access_staff_communication_thread(thread_id))
 and lower(sender_email)=lower(coalesce(auth.jwt()->>'email',''))
 and (((select private.is_admin()) and sender_role='ADMIN') or ((select private.current_staff_id()) is not null and sender_role in ('TEACHER','STAFF')))
);

drop policy if exists staff_comm_reads_select on public.staff_communication_reads;
create policy staff_comm_reads_select on public.staff_communication_reads for select to authenticated using (
 lower(reader_email)=lower(coalesce(auth.jwt()->>'email','')) and (select private.can_access_staff_communication_thread(thread_id))
);
drop policy if exists staff_comm_reads_insert on public.staff_communication_reads;
create policy staff_comm_reads_insert on public.staff_communication_reads for insert to authenticated with check (
 lower(reader_email)=lower(coalesce(auth.jwt()->>'email','')) and (select private.can_access_staff_communication_thread(thread_id))
);
drop policy if exists staff_comm_reads_update on public.staff_communication_reads;
create policy staff_comm_reads_update on public.staff_communication_reads for update to authenticated using (
 lower(reader_email)=lower(coalesce(auth.jwt()->>'email','')) and (select private.can_access_staff_communication_thread(thread_id))
) with check (
 lower(reader_email)=lower(coalesce(auth.jwt()->>'email','')) and (select private.can_access_staff_communication_thread(thread_id))
);

do $$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='staff_communication_threads') then alter publication supabase_realtime add table public.staff_communication_threads; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='staff_communication_messages') then alter publication supabase_realtime add table public.staff_communication_messages; end if;
end $$;