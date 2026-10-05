-- Student portal security and performance hardening.
-- Applied to production Supabase.
-- Adds dashboard/RLS indexes, caches auth helper calls in RLS policies,
-- removes unnecessary authenticated execution of anonymous student RPCs,
-- and restricts direct authenticated dashboard reads to admins/assigned teachers.

-- See production migration history for the complete SQL:
-- student_portal_security_performance_hardening
