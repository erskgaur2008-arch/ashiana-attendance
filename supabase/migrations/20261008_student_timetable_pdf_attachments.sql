-- Student Portal timetable PDF attachments.
alter table public.student_timetable
  add column if not exists attachment_path text,
  add column if not exists attachment_name text;

notify pgrst, 'reload schema';
