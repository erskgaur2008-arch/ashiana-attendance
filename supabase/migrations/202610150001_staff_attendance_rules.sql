-- Staff attendance rules settings and audit trail.
-- Apply to an isolated test project first. Do not apply to production without approval.
CREATE TABLE IF NOT EXISTS public.staff_attendance_rules (
  id text PRIMARY KEY DEFAULT 'default',
  rules jsonb NOT NULL DEFAULT '{"schoolScheduleStart":"07:40","schoolScheduleEnd":"14:30","lateGraceMinutes":10,"lateAfter":"07:50","attendanceDenominator":"working_days","approvedLeaveTreatment":"separate","fullDayMinimumHours":0}'::jsonb,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text,
  CONSTRAINT staff_attendance_rules_singleton CHECK (id = 'default')
);
ALTER TABLE public.staff_attendance_rules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "active admins can read staff attendance rules" ON public.staff_attendance_rules;
CREATE POLICY "active admins can read staff attendance rules" ON public.staff_attendance_rules
FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
);
DROP POLICY IF EXISTS "active admins can insert staff attendance rules" ON public.staff_attendance_rules;
CREATE POLICY "active admins can insert staff attendance rules" ON public.staff_attendance_rules
FOR INSERT TO authenticated WITH CHECK (
  id='default' AND EXISTS (SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
);
DROP POLICY IF EXISTS "active admins can update staff attendance rules" ON public.staff_attendance_rules;
CREATE POLICY "active admins can update staff attendance rules" ON public.staff_attendance_rules
FOR UPDATE TO authenticated USING (
  EXISTS (SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
) WITH CHECK (
  id='default' AND EXISTS (SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
);
GRANT SELECT, INSERT, UPDATE ON public.staff_attendance_rules TO authenticated;
REVOKE ALL ON public.staff_attendance_rules FROM anon;
INSERT INTO public.staff_attendance_rules(id,rules) VALUES ('default',
 '{"schoolScheduleStart":"07:40","schoolScheduleEnd":"14:30","lateGraceMinutes":10,"lateAfter":"07:50","attendanceDenominator":"working_days","approvedLeaveTreatment":"separate","fullDayMinimumHours":0}'::jsonb)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.staff_attendance_rules_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_version integer NOT NULL,
  rules jsonb NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by text
);
ALTER TABLE public.staff_attendance_rules_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "active admins can read staff attendance rules history" ON public.staff_attendance_rules_history;
CREATE POLICY "active admins can read staff attendance rules history" ON public.staff_attendance_rules_history
FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
);
DROP POLICY IF EXISTS "active admins can insert staff attendance rules history" ON public.staff_attendance_rules_history;
CREATE POLICY "active admins can insert staff attendance rules history" ON public.staff_attendance_rules_history
FOR INSERT TO authenticated WITH CHECK (
  EXISTS (SELECT 1 FROM public.admin_users au
    WHERE lower(au.email)=lower((SELECT auth.jwt()->>'email'))
      AND au.active=true AND au.role IN ('ADMIN','SUPER_ADMIN'))
);
GRANT SELECT, INSERT ON public.staff_attendance_rules_history TO authenticated;
REVOKE ALL ON public.staff_attendance_rules_history FROM anon;
