-- Harden public login-home RPC against search_path object shadowing.
-- The function reads only explicitly schema-qualified public tables; it does not
-- require public/private to be on search_path. Keep this staged until reviewed.

begin;

alter function public.public_login_home_content(text) set search_path = '';

commit;
