-- Atomically consume a single unexpired WebAuthn challenge.
-- This prevents two concurrent requests from verifying the same challenge.
create or replace function public.consume_staff_webauthn_challenge(
  p_staff_id text,
  p_purpose text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  consumed_challenge text;
begin
  if p_purpose not in ('registration', 'attendance') then
    return null;
  end if;

  with candidate as (
    select c.id
    from public.staff_webauthn_challenges as c
    where c.staff_id = p_staff_id
      and c.purpose = p_purpose
      and c.expires_at > pg_catalog.now()
    order by c.created_at desc
    limit 1
    for update skip locked
  )
  delete from public.staff_webauthn_challenges as c
  using candidate
  where c.id = candidate.id
  returning c.challenge into consumed_challenge;

  return consumed_challenge;
end;
$$;

revoke all on function public.consume_staff_webauthn_challenge(text, text) from public, anon, authenticated;
grant execute on function public.consume_staff_webauthn_challenge(text, text) to service_role;
