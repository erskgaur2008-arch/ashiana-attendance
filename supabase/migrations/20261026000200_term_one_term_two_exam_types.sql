-- Expand exam types to match the school's Term I / Term II assessment structure.
-- Existing exam records are preserved; only the accepted exam_type values change.
alter table public.school_exams
  drop constraint if exists school_exams_exam_type_check;

alter table public.school_exams
  add constraint school_exams_exam_type_check
  check (exam_type in (
    'Unit Test', 'Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV',
    'Internal Assessment-I', 'Internal Assessment-II',
    'Internal Assessment-III', 'Internal Assessment-IV',
    'Term', 'Term I', 'Term II', 'Half-Yearly', 'Annual', 'Other'
  ));
