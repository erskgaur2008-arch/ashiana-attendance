-- Per-month school working-day calendar, separate from attendance punches and calculations.
-- Apply to EduPunch-Test first. Do not apply to production without explicit approval.
CREATE TABLE IF NOT EXISTS public.monthly_working_day_calendars (
  month_key date PRIMARY KEY,
  calendar jsonb NOT NULL,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text,
  CONSTRAINT monthly_working_day_calendar_month_start CHECK (EXTRACT(DAY FROM month_key) = 1),
  CONSTRAINT monthly_working_day_calendar_object CHECK (jsonb_typeof(calendar) = 'object')
);
ALTER TABLE public.monthly_working_day_calendars ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "active admins can read monthly working day calendars" ON public.monthly_working_day_calendars;
CREATE POLICY "active admins can read monthly working day calendars" ON public.monthly_working_day_calendars
FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
);
DROP POLICY IF EXISTS "active admins can insert monthly working day calendars" ON public.monthly_working_day_calendars;
CREATE POLICY "active admins can insert monthly working day calendars" ON public.monthly_working_day_calendars
FOR INSERT TO authenticated WITH CHECK (
  EXTRACT(DAY FROM month_key)=1 AND jsonb_typeof(calendar)='object' AND EXISTS (
    SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
);
DROP POLICY IF EXISTS "active admins can update monthly working day calendars" ON public.monthly_working_day_calendars;
CREATE POLICY "active admins can update monthly working day calendars" ON public.monthly_working_day_calendars
FOR UPDATE TO authenticated USING (
  EXISTS (SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
) WITH CHECK (
  EXTRACT(DAY FROM month_key)=1 AND jsonb_typeof(calendar)='object' AND EXISTS (
    SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
);
GRANT SELECT, INSERT, UPDATE ON public.monthly_working_day_calendars TO authenticated;
REVOKE ALL ON public.monthly_working_day_calendars FROM anon;
