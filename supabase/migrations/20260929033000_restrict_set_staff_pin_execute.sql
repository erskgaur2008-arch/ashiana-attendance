-- Keep staff PIN changes behind authenticated identity checks in the function body.
-- Remove PostgreSQL's default PUBLIC execution path and explicitly allow signed-in callers.
REVOKE EXECUTE ON FUNCTION public.set_staff_pin(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_staff_pin(text, text) TO authenticated;
