-- Covering indexes for foreign keys flagged by Supabase Performance Advisor.
-- Applied to production as migration: student_fk_performance_indexes.

create index if not exists student_attendance_student_id_idx on public.student_attendance (student_id);
create index if not exists student_leave_student_id_idx on public.student_leave_requests (student_id);
create index if not exists student_report_student_id_idx on public.student_report_cards (student_id);
