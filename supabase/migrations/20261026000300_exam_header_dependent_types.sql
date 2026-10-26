-- Store the exam header separately from its assessment type.
-- Existing exams are preserved and categorized from their existing type where unambiguous.
alter table public.school_exams
  add column if not exists exam_header text not null default 'Other';

update public.school_exams
set exam_header = case
  when exam_type in ('Unit Test-III','Unit Test-IV','Internal Assessment-III','Internal Assessment-IV','Annual','Term II') then 'Term II'
  when exam_type in ('Unit Test-I','Unit Test-II','Internal Assessment-I','Internal Assessment-II','Half-Yearly','Term I') then 'Term I'
  else 'Other'
end
where exam_header = 'Other';

alter table public.school_exams
  drop constraint if exists school_exams_exam_header_check;

alter table public.school_exams
  add constraint school_exams_exam_header_check
  check (exam_header in ('Term I','Term II','Other'));
