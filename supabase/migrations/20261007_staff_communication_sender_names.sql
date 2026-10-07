-- Persist display names for Staff ↔ Administration messages.
-- The trigger resolves the sender name server-side so normal staff users do not
-- need SELECT access to other staff records.

alter table public.staff_communication_messages
  add column if not exists sender_name text;

create or replace function public.staff_communication_set_sender_name()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if upper(coalesce(new.sender_role,''))='ADMIN' then
    new.sender_name := 'Administration';
  else
    select s.name into new.sender_name
    from public.staff s
    where s.status='ACTIVE'
      and lower(s.email)=lower(new.sender_email)
    limit 1;
    new.sender_name := coalesce(nullif(trim(new.sender_name),''),new.sender_role);
  end if;
  return new;
end;
$function$;

revoke all on function public.staff_communication_set_sender_name() from public, anon, authenticated;

drop trigger if exists trg_staff_communication_set_sender_name
  on public.staff_communication_messages;

create trigger trg_staff_communication_set_sender_name
before insert on public.staff_communication_messages
for each row execute function public.staff_communication_set_sender_name();

update public.staff_communication_messages m
set sender_name=case
  when upper(coalesce(m.sender_role,''))='ADMIN' then 'Administration'
  else coalesce(nullif(trim(s.name),''),m.sender_role)
end
from public.staff s
where upper(coalesce(m.sender_role,''))<>'ADMIN'
  and lower(s.email)=lower(m.sender_email)
  and m.sender_name is distinct from coalesce(nullif(trim(s.name),''),m.sender_role);

update public.staff_communication_messages
set sender_name='Administration'
where upper(coalesce(sender_role,''))='ADMIN'
  and sender_name is distinct from 'Administration';

notify pgrst,'reload schema';