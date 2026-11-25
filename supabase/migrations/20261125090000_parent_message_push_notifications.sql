-- Push notifications for two-way Parent–School Messaging.
-- Recipient IDs are resolved server-side; no student or staff tokens are exposed.

create table if not exists public.parent_message_push_deliveries (
  message_id uuid primary key references public.parent_message_messages(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.parent_message_push_deliveries enable row level security;
revoke all on public.parent_message_push_deliveries from public, anon, authenticated;
grant all on public.parent_message_push_deliveries to service_role;

create or replace function public.parent_messages_notification_target_users(p_thread_id uuid)
returns table(user_id uuid)
language sql
stable
security definer
set search_path = ''
as $function$
  select distinct u.id
    from public.parent_message_threads t
    join public.staff st on upper(coalesce(st.status, '')) = 'ACTIVE'
    join auth.users u on lower(btrim(u.email)) = lower(btrim(st.email))
   where t.id = p_thread_id
     and (
       (t.recipient_type = 'TEACHER' and st.id = t.recipient_staff_id)
       or (t.recipient_type = 'PRINCIPAL' and lower(btrim(st.role)) in ('principal', 'vice principal'))
       or (t.recipient_type = 'SCHOOL_ADMINISTRATION' and lower(btrim(st.role)) = 'admin')
     )
  union
  select distinct u.id
    from public.parent_message_threads t
    join public.admin_users a on a.active is true
    join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
   where t.id = p_thread_id and t.recipient_type = 'SCHOOL_ADMINISTRATION';
$function$;

revoke all on function public.parent_messages_notification_target_users(uuid) from public, anon, authenticated;
grant execute on function public.parent_messages_notification_target_users(uuid) to service_role;

notify pgrst, 'reload schema';
