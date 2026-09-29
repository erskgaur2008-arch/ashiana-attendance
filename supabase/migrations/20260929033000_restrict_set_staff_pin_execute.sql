-- Restrict staff PIN mutation RPC execution to authenticated callers.
-- The function performs its own identity and active-membership authorization checks.
REVOKE EXECUTE ON FUNCTION public.set_staff_pin(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_staff_pin(text, text) TO authenticated;
