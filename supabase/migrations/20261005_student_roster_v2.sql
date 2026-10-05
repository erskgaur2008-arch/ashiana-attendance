-- Student roster v2: enroll-based identity and Active / Inactive-Passout status.
alter table public.student_roster rename column admission_no to enroll_no;
alter table public.student_roster drop constraint if exists student_roster_status_check;
alter table public.student_roster add constraint student_roster_status_check check (status in ('ACTIVE','INACTIVE_PASSOUT'));
drop index if exists student_roster_class_section_roll_uidx;
create unique index if not exists student_roster_school_enroll_uidx on public.student_roster (school_code,enroll_no);
create index if not exists student_roster_active_class_idx on public.student_roster (school_code,class_name,section,status,roll_no);
