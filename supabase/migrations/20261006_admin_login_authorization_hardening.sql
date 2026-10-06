-- Harden administrator login authorization.
-- The browser first authenticates with Supabase Auth, then calls this
-- SECURITY DEFINER function to verify the email against the active admin list.
create or replace function public.authorize_admin_login()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select jsonb_build_object(
        'authorized', true,
        'email', a.email,
        'role', a.role
      )
      from public.admin_users a
      where a.active = true
        and lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      limit 1
    ),
    jsonb_build_object('authorized', false)
  );
$$;

revoke all on function public.authorize_admin_login() from public, anon;
grant execute on function public.authorize_admin_login() to authenticated;
