-- Communication closed-state enforcement
-- Admin or the conversation creator may close a thread.
-- Once CLOSED, no authenticated user can insert another message.

create or replace function private.staff_communication_guard_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_email text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if (select private.is_admin()) then
    return new;
  end if;

  if lower(coalesce(old.created_by_email,'')) <> caller_email then
    raise exception 'Only the administrator or conversation creator can close this conversation.';
  end if;

  if new.status <> 'CLOSED' then
    raise exception 'The conversation creator can only mark the conversation CLOSED.';
  end if;

  if new.subject is distinct from old.subject
     or new.category is distinct from old.category
     or new.priority is distinct from old.priority
     or new.audience is distinct from old.audience
     or new.created_by_email is distinct from old.created_by_email
     or new.created_by_role is distinct from old.created_by_role
     or new.recipient_staff_id is distinct from old.recipient_staff_id
     or new.created_at is distinct from old.created_at
     or new.last_message_at is distinct from old.last_message_at then
    raise exception 'Conversation details cannot be changed by the creator.';
  end if;

  return new;
end;
$$;

revoke all on function private.staff_communication_guard_update() from public, anon, authenticated;

drop trigger if exists trg_staff_communication_guard_update on public.staff_communication_threads;
create trigger trg_staff_communication_guard_update
before update on public.staff_communication_threads
for each row execute function private.staff_communication_guard_update();

drop policy if exists staff_comm_threads_update on public.staff_communication_threads;
create policy staff_comm_threads_update
on public.staff_communication_threads
for update to authenticated
using (
  (select private.is_admin())
  or lower(created_by_email)=lower(coalesce(auth.jwt()->>'email',''))
)
with check (
  (select private.is_admin())
  or (
    lower(created_by_email)=lower(coalesce(auth.jwt()->>'email',''))
    and status='CLOSED'
  )
);

create or replace function private.staff_communication_block_closed_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.staff_communication_threads t
    where t.id=new.thread_id
      and t.status='CLOSED'
  ) then
    raise exception 'This conversation is closed. Nobody can send new messages.';
  end if;
  return new;
end;
$$;

revoke all on function private.staff_communication_block_closed_message() from public, anon, authenticated;

drop trigger if exists trg_staff_communication_block_closed_message on public.staff_communication_messages;
create trigger trg_staff_communication_block_closed_message
before insert on public.staff_communication_messages
for each row execute function private.staff_communication_block_closed_message();

drop policy if exists staff_comm_messages_insert on public.staff_communication_messages;
create policy staff_comm_messages_insert
on public.staff_communication_messages
for insert to authenticated
with check (
  (select private.can_access_staff_communication_thread(thread_id))
  and exists (
    select 1
    from public.staff_communication_threads t
    where t.id=thread_id
      and t.status <> 'CLOSED'
  )
  and lower(sender_email)=lower(coalesce(auth.jwt()->>'email',''))
  and (
    ((select private.is_admin()) and sender_role='ADMIN')
    or ((select private.current_staff_id()) is not null and sender_role in ('TEACHER','STAFF'))
  )
);

notify pgrst, 'reload schema';
