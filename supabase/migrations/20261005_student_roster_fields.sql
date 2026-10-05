-- Student roster extensions used by the production student attendance workflow.
alter table public.student_roster drop constraint if exists student_roster_school_code_admission_no_key;
alter table public.student_roster add column if not exists gender text;
alter table public.student_roster add column if not exists category text;
alter table public.student_roster drop constraint if exists student_roster_status_check;
alter table public.student_roster add constraint student_roster_status_check check (status in ('ACTIVE','INACTIVE','LEFT_PASSOUT'));
create unique index if not exists student_roster_class_section_roll_uidx on public.student_roster (school_code,class_name,section,roll_no) where roll_no is not null;
