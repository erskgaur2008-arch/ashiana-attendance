-- Class-band report card formats, grade-only subjects, and term components.
-- Review before applying this migration to a live database.

alter table public.exam_marks
  add column if not exists grade text;

alter table public.exam_class_subjects
  add column if not exists grading_mode text not null default 'marks';

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.exam_class_subjects'::regclass
       and conname = 'exam_class_subjects_grading_mode_check'
  ) then
    alter table public.exam_class_subjects
      add constraint exam_class_subjects_grading_mode_check
      check (grading_mode in ('marks', 'grade'));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.exam_marks'::regclass
       and conname = 'exam_marks_grade_check'
  ) then
    alter table public.exam_marks
      add constraint exam_marks_grade_check
      check (grade is null or grade in ('A1', 'A2', 'B1', 'B2', 'C1', 'C2', 'D', 'E'));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.exam_marks'::regclass
       and conname = 'exam_marks_marks_grade_exclusive_check'
  ) then
    alter table public.exam_marks
      add constraint exam_marks_marks_grade_exclusive_check
      check (not (marks is not null and grade is not null));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.exam_marks'::regclass
       and conname = 'exam_marks_absent_values_check'
  ) then
    alter table public.exam_marks
      add constraint exam_marks_absent_values_check
      check (not is_absent or (marks is null and grade is null));
  end if;
end
$constraints$;

insert into public.school_subjects (school_code, subject_code, subject_name, active)
values
  ('ashiana', 'ART', 'Art & Craft', true),
  ('ashiana', 'GK', 'G.K.', true)
on conflict do nothing;

update public.school_subjects
   set active = true
 where school_code = 'ashiana'
   and lower(btrim(subject_name)) in ('art & craft', 'g.k.');

alter table public.exam_class_subjects
  drop constraint if exists exam_class_subjects_report_card_format_check;

alter table public.exam_class_subjects
  add constraint exam_class_subjects_report_card_format_check
  check (report_card_format in (
    'class_specific',
    'class_iii_iv_result_cum_marksheet',
    'class_v_result_cum_marksheet',
    'class_vi_viii_result_cum_marksheet',
    'existing'
  ));

create or replace function private.report_card_apply_exam_defaults(p_exam_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update public.exam_class_subjects c
     set active = false,
         updated_at = now()
    from public.school_subjects s
    join public.school_exams e on e.id = p_exam_id
   where c.exam_id = p_exam_id
     and c.subject_id = s.id
     and c.school_code = 'ashiana'
     and upper(btrim(c.class_name)) in ('III', 'IV', 'V', 'VI', 'VII', 'VIII')
     and e.exam_type in (
       'Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV',
       'Internal Assessment-I', 'Internal Assessment-II',
       'Internal Assessment-III', 'Internal Assessment-IV',
       'Half-Yearly', 'Annual'
     )
     and not (
       (
         upper(btrim(c.class_name)) in ('III', 'IV')
         and e.exam_type in (
           'Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV',
           'Internal Assessment-I', 'Internal Assessment-II',
           'Internal Assessment-III', 'Internal Assessment-IV'
         )
         and (
           lower(btrim(s.subject_name)) in ('english', 'hindi', 'mathematics', 'evs', 'french')
           or (lower(btrim(s.subject_name)) in ('computer', 'art & craft', 'g.k.')
               and e.exam_type = 'Internal Assessment-IV')
         )
       )
       or (
         upper(btrim(c.class_name)) in ('V', 'VI', 'VII', 'VIII')
         and e.exam_type in (
           'Unit Test-I', 'Unit Test-II', 'Internal Assessment-I',
           'Internal Assessment-II', 'Half-Yearly', 'Annual'
         )
         and (
           lower(btrim(s.subject_name)) in ('english', 'hindi', 'mathematics', 'science', 'social science', 'punjabi')
           or (lower(btrim(s.subject_name)) in ('computer', 'art & craft', 'g.k.')
               and e.exam_type = 'Annual')
         )
       )
     );

  insert into public.exam_class_subjects (
    school_code, exam_id, academic_session_id, class_name, section,
    subject_id, max_marks, grading_mode, report_card_format,
    assessment_config, active, updated_at
  )
  select
    e.school_code,
    e.id,
    e.academic_session_id,
    cs.class_name,
    cs.section,
    s.id,
    case
      when lower(btrim(s.subject_name)) in ('computer', 'art & craft', 'g.k.') then 100
      when upper(btrim(cs.class_name)) in ('III', 'IV')
       and e.exam_type in ('Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV') then 35
      when upper(btrim(cs.class_name)) in ('III', 'IV')
       and e.exam_type in ('Internal Assessment-I', 'Internal Assessment-II', 'Internal Assessment-III', 'Internal Assessment-IV') then 15
      when upper(btrim(cs.class_name)) in ('V', 'VI', 'VII', 'VIII')
       and e.exam_type in ('Unit Test-I', 'Unit Test-II') then 30
      when upper(btrim(cs.class_name)) in ('V', 'VI', 'VII', 'VIII')
       and e.exam_type in ('Internal Assessment-I', 'Internal Assessment-II') then 20
      when upper(btrim(cs.class_name)) in ('V', 'VI', 'VII', 'VIII')
       and e.exam_type in ('Half-Yearly', 'Annual') then 50
      else 100
    end,
    case
      when lower(btrim(s.subject_name)) in ('computer', 'art & craft', 'g.k.') then 'grade'
      else 'marks'
    end,
    case
      when upper(btrim(cs.class_name)) in ('III', 'IV') then 'class_iii_iv_result_cum_marksheet'
      when upper(btrim(cs.class_name)) = 'V' then 'class_v_result_cum_marksheet'
      else 'class_vi_viii_result_cum_marksheet'
    end,
    case
      when lower(btrim(s.subject_name)) in ('computer', 'art & craft', 'g.k.') then
        jsonb_build_array(jsonb_build_object('key', 'grade', 'label', 'Grade', 'kind', 'grade'))
      else jsonb_build_array(jsonb_build_object(
        'key', e.exam_type,
        'label', e.exam_name,
        'term', e.exam_header,
        'kind', 'marks'
      ))
    end,
    true,
    now()
  from public.school_exams e
  join (
    select distinct r.class_name, r.section
      from public.student_roster r
     where r.school_code = 'ashiana'
       and upper(coalesce(r.status, '')) = 'ACTIVE'
       and upper(btrim(r.class_name)) in ('III', 'IV', 'V', 'VI', 'VII', 'VIII')
  ) cs on true
  cross join lateral unnest(
    case
      when upper(btrim(cs.class_name)) in ('III', 'IV') then array[
        'English', 'Hindi', 'Mathematics', 'EVS', 'French',
        'Computer', 'Art & Craft', 'G.K.'
      ]::text[]
      else array[
        'English', 'Hindi', 'Mathematics', 'Science', 'Social Science', 'Punjabi',
        'Computer', 'Art & Craft', 'G.K.'
      ]::text[]
    end
  ) as wanted(subject_name)
  join public.school_subjects s
    on s.school_code = e.school_code
   and lower(btrim(s.subject_name)) = lower(btrim(wanted.subject_name))
   and s.active
  where e.id = p_exam_id
    and e.school_code = 'ashiana'
    and (
      (
        upper(btrim(cs.class_name)) in ('III', 'IV')
        and e.exam_type in (
          'Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV',
          'Internal Assessment-I', 'Internal Assessment-II',
          'Internal Assessment-III', 'Internal Assessment-IV'
        )
        and (
          lower(btrim(s.subject_name)) in ('english', 'hindi', 'mathematics', 'evs', 'french')
          or (lower(btrim(s.subject_name)) in ('computer', 'art & craft', 'g.k.')
              and e.exam_type = 'Internal Assessment-IV')
        )
      )
      or (
        upper(btrim(cs.class_name)) in ('V', 'VI', 'VII', 'VIII')
        and e.exam_type in (
          'Unit Test-I', 'Unit Test-II', 'Internal Assessment-I',
          'Internal Assessment-II', 'Half-Yearly', 'Annual'
        )
        and (
          lower(btrim(s.subject_name)) in ('english', 'hindi', 'mathematics', 'science', 'social science', 'punjabi')
          or (lower(btrim(s.subject_name)) in ('computer', 'art & craft', 'g.k.')
              and e.exam_type = 'Annual')
        )
      )
    )
  on conflict (exam_id, class_name, section, subject_id) do update
    set academic_session_id = excluded.academic_session_id,
        max_marks = excluded.max_marks,
        grading_mode = excluded.grading_mode,
        report_card_format = excluded.report_card_format,
        assessment_config = excluded.assessment_config,
        active = true,
        updated_at = now();
end
$function$;

revoke all on function private.report_card_apply_exam_defaults(uuid) from public, anon, authenticated;

-- Retain any numeric grade-area values already entered for a final assessment
-- by converting them with the mapping's original maximum before reseeding it.
update public.exam_marks m
   set grade = private.report_grade(round(m.marks * 100 / nullif(c.max_marks, 0), 2)),
       marks = null
  from public.exam_class_subjects c,
       public.school_subjects s,
       public.school_exams e,
       public.student_roster r
 where c.subject_id = s.id
   and e.id = c.exam_id
   and r.class_name = c.class_name
   and r.section = c.section
   and r.id = m.student_id
   and m.exam_id = e.id
   and m.subject_id = s.id
   and c.school_code = 'ashiana'
   and e.school_code = 'ashiana'
   and r.school_code = 'ashiana'
   and upper(btrim(c.class_name)) in ('III', 'IV', 'V', 'VI', 'VII', 'VIII')
   and (
     (upper(btrim(c.class_name)) in ('III', 'IV') and e.exam_type = 'Internal Assessment-IV')
     or (upper(btrim(c.class_name)) in ('V', 'VI', 'VII', 'VIII') and e.exam_type = 'Annual')
   )
   and lower(btrim(s.subject_name)) in ('computer', 'art & craft', 'g.k.')
   and m.marks is not null
   and m.grade is null
   and not m.is_absent
   and c.max_marks > 0;

do $backfill$
declare
  v_exam record;
begin
  for v_exam in
    select e.id from public.school_exams e where e.school_code = 'ashiana'
  loop
    perform private.report_card_apply_exam_defaults(v_exam.id);
  end loop;
end
$backfill$;

create or replace function private.report_card_seed_exam_classes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.school_code = 'ashiana' then
    perform private.report_card_apply_exam_defaults(new.id);
  end if;
  return new;
end
$function$;

revoke all on function private.report_card_seed_exam_classes() from public, anon, authenticated;

drop trigger if exists report_card_seed_exam_classes on public.school_exams;
create trigger report_card_seed_exam_classes
  after insert on public.school_exams
  for each row execute function private.report_card_seed_exam_classes();

-- Ensure the active (or already configured) academic session has every
-- assessment component used by the supplied marksheets. Existing assessments
-- of the same type are reused.
with required_assessments(exam_type, exam_name, exam_header) as (
  values
    ('Unit Test-I', 'Unit Test I', 'Term I'),
    ('Unit Test-II', 'Unit Test II', 'Term I'),
    ('Unit Test-III', 'Unit Test III', 'Term II'),
    ('Unit Test-IV', 'Unit Test IV', 'Term II'),
    ('Internal Assessment-I', 'Internal Assessment I', 'Term I'),
    ('Internal Assessment-II', 'Internal Assessment II', 'Term I'),
    ('Internal Assessment-III', 'Internal Assessment III', 'Term II'),
    ('Internal Assessment-IV', 'Internal Assessment IV', 'Term II'),
    ('Half-Yearly', 'Half Yearly', 'Term I'),
    ('Annual', 'Annual', 'Term II')
)
insert into public.school_exams (
  school_code, academic_session_id, exam_name, exam_type, exam_header, status
)
select
  a.school_code, a.id, d.exam_name, d.exam_type, d.exam_header, 'Draft'
from (
  select s.id, s.school_code
    from public.academic_sessions s
   where s.school_code = 'ashiana'
     and (
       s.is_active
       or exists (
         select 1
           from public.school_exams existing_exam
          where existing_exam.school_code = s.school_code
            and existing_exam.academic_session_id = s.id
       )
     )
   order by s.is_active desc, s.starts_on desc, s.label desc
   limit 1
) a
cross join required_assessments d
where not exists (
    select 1 from public.school_exams e
     where e.school_code = a.school_code
       and e.academic_session_id = a.id
       and e.exam_type = d.exam_type
  )
on conflict (school_code, academic_session_id, exam_name) do nothing;

create or replace function public.report_card_exam_options()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin boolean := coalesce(private.is_admin(), false);
begin
  if auth.uid() is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'exam_id', x.exam_id,
      'exam_name', x.exam_name,
      'exam_type', x.exam_type,
      'exam_header', x.exam_header,
      'academic_session', x.academic_session,
      'class_name', x.class_name,
      'section', x.section,
      'report_card_format', x.report_card_format,
      'status', coalesce(p.status, 'DRAFT'),
      'is_class_teacher', private.report_is_class_teacher(x.class_name, x.section)
    ) order by x.academic_session desc, x.exam_header, x.exam_name, x.class_name, x.section)
    from (
      select distinct e.id as exam_id, e.exam_name, e.exam_type, e.exam_header,
             a.label as academic_session, c.class_name, c.section, c.report_card_format
        from public.school_exams e
        join public.academic_sessions a on a.id = e.academic_session_id
        join public.exam_class_subjects c on c.exam_id = e.id and c.active
       where e.school_code = 'ashiana'
         and (v_admin or private.report_is_class_teacher(c.class_name, c.section))
    ) x
    left join public.exam_publications p
      on p.exam_id = x.exam_id
     and p.class_name = x.class_name
     and p.section = x.section
  ), '[]'::jsonb);
end
$function$;

create or replace function public.report_card_sheet(
  p_exam_id uuid,
  p_class text,
  p_section text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin boolean := coalesce(private.is_admin(), false);
  v_publication public.exam_publications%rowtype;
  v_exam public.school_exams%rowtype;
begin
  if auth.uid() is null
     or not (v_admin or private.report_is_class_teacher(p_class, p_section)) then
    raise exception 'Not allowed for this class' using errcode = '42501';
  end if;

  select * into v_exam from public.school_exams where id = p_exam_id and school_code = 'ashiana';
  if not found then raise exception 'Exam not found'; end if;

  select * into v_publication
    from public.exam_publications
   where exam_id = p_exam_id and class_name = p_class and section = p_section;

  return jsonb_build_object(
    'exam_id', v_exam.id,
    'exam_name', v_exam.exam_name,
    'exam_type', v_exam.exam_type,
    'exam_header', v_exam.exam_header,
    'academic_session', (select a.label from public.academic_sessions a where a.id = v_exam.academic_session_id),
    'report_card_format', coalesce((
      select c.report_card_format from public.exam_class_subjects c
       where c.exam_id = p_exam_id and c.class_name = p_class and c.section = p_section and c.active
       order by c.created_at limit 1
    ), 'class_specific'),
    'status', coalesce(v_publication.status, 'DRAFT'),
    'review_note', v_publication.review_note,
    'subjects', coalesce((
      select jsonb_agg(jsonb_build_object(
        'subject_id', s.id,
        'code', s.subject_code,
        'name', s.subject_name,
        'max_marks', c.max_marks,
        'grading_mode', c.grading_mode,
        'grade_only', c.grading_mode = 'grade',
        'assessment_config', c.assessment_config
      ) order by case when c.grading_mode = 'grade' then 1 else 0 end, s.subject_name)
        from public.exam_class_subjects c
        join public.school_subjects s on s.id = c.subject_id
       where c.exam_id = p_exam_id and c.class_name = p_class and c.section = p_section and c.active
    ), '[]'::jsonb),
    'students', coalesce((
      select jsonb_agg(jsonb_build_object(
        'student_id', r.id,
        'enroll_no', r.enroll_no,
        'roll_no', r.roll_no,
        'name', r.student_name
      ) order by nullif(regexp_replace(coalesce(r.roll_no, ''), '\D', '', 'g'), '')::int nulls last, r.student_name)
        from public.student_roster r
       where r.school_code = 'ashiana'
         and r.class_name = p_class
         and r.section = p_section
         and upper(coalesce(r.status, '')) = 'ACTIVE'
    ), '[]'::jsonb),
    'marks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'student_id', m.student_id,
        'subject_id', m.subject_id,
        'marks', m.marks,
        'grade', m.grade,
        'absent', m.is_absent
      ))
        from public.exam_marks m
        join public.student_roster r on r.id = m.student_id
       where m.exam_id = p_exam_id and r.class_name = p_class and r.section = p_section
    ), '[]'::jsonb)
  );
end
$function$;

create or replace function public.report_card_save_marks(
  p_exam_id uuid,
  p_class text,
  p_section text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_status text;
  r jsonb;
  v_student uuid;
  v_subject uuid;
  v_max numeric;
  v_grading_mode text;
  v_marks numeric;
  v_grade text;
  v_absent boolean;
  v_errors jsonb := '[]'::jsonb;
  v_clean jsonb := '[]'::jsonb;
  v_saved integer := 0;
  v_row integer := 0;
  v_raw text;
begin
  if auth.uid() is null
     or not (coalesce(private.is_admin(), false) or private.report_is_class_teacher(p_class, p_section)) then
    raise exception 'Only the class teacher can enter marks for this class' using errcode = '42501';
  end if;
  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception 'Invalid marks upload';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'Invalid marks upload';
  end if;

  select status into v_status
    from public.exam_publications
   where exam_id = p_exam_id and class_name = p_class and section = p_section;
  if v_status in ('SUBMITTED', 'APPROVED') then
    return jsonb_build_object(
      'success', false,
      'message', 'Marks are locked (' || v_status || '). Ask the admin to return them for correction.'
    );
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_row := v_row + 1;
    select id into v_student
      from public.student_roster
     where school_code = 'ashiana'
       and class_name = p_class
       and section = p_section
       and upper(btrim(enroll_no)) = upper(btrim(coalesce(r ->> 'enroll_no', '')))
       and upper(coalesce(status, '')) = 'ACTIVE';
    select s.id, c.max_marks, c.grading_mode into v_subject, v_max, v_grading_mode
      from public.exam_class_subjects c
      join public.school_subjects s on s.id = c.subject_id
     where c.exam_id = p_exam_id and c.class_name = p_class and c.section = p_section
       and c.active
       and upper(btrim(s.subject_code)) = upper(btrim(coalesce(r ->> 'subject_code', '')));

    v_raw := nullif(btrim(coalesce(r ->> 'marks', '')), '');
    v_grade := nullif(upper(btrim(coalesce(r ->> 'grade', ''))), '');
    v_absent := coalesce((r ->> 'absent')::boolean, false);
    v_marks := null;
    if v_student is null then
      v_errors := v_errors || jsonb_build_object('row', v_row, 'error', 'Student ' || coalesce(r ->> 'enroll_no', '?') || ' is not in this class');
    elsif v_subject is null then
      v_errors := v_errors || jsonb_build_object('row', v_row, 'error', 'Subject ' || coalesce(r ->> 'subject_code', '?') || ' is not part of this exam');
    elsif v_absent and (v_raw is not null or v_grade is not null) then
      v_errors := v_errors || jsonb_build_object('row', v_row, 'error', 'Absent rows cannot also contain a mark or grade');
    elsif v_grading_mode = 'grade' and v_raw is not null then
      v_errors := v_errors || jsonb_build_object('row', v_row, 'error', 'Subject ' || (r ->> 'subject_code') || ' accepts a grade, not numeric marks');
    elsif v_grading_mode = 'grade' and v_grade is not null and v_grade not in ('A1', 'A2', 'B1', 'B2', 'C1', 'C2', 'D', 'E') then
      v_errors := v_errors || jsonb_build_object('row', v_row, 'error', 'Invalid grade for ' || (r ->> 'subject_code') || '. Use A1, A2, B1, B2, C1, C2, D, or E.');
    elsif v_grading_mode <> 'grade' and v_grade is not null then
      v_errors := v_errors || jsonb_build_object('row', v_row, 'error', 'Subject ' || (r ->> 'subject_code') || ' accepts numeric marks, not a grade');
    else
      if v_grading_mode <> 'grade' and v_raw is not null then
        if v_raw !~ '^[0-9]{1,5}(\.[0-9]{1,2})?$' then
          v_errors := v_errors || jsonb_build_object('row', v_row, 'error', 'Invalid marks "' || v_raw || '" for ' || (r ->> 'enroll_no'));
          continue;
        end if;
        v_marks := v_raw::numeric;
        if v_marks > v_max then
          v_errors := v_errors || jsonb_build_object('row', v_row, 'error', 'Marks ' || v_marks || ' exceed maximum ' || v_max || ' (' || (r ->> 'enroll_no') || ')');
          continue;
        end if;
      end if;
      v_clean := v_clean || jsonb_build_object(
        'student_id', v_student,
        'subject_id', v_subject,
        'marks', v_marks,
        'grade', case when v_grading_mode = 'grade' then v_grade else null end,
        'absent', v_absent
      );
    end if;
  end loop;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('success', false, 'message', 'Nothing was saved. Fix the rows below and upload again.', 'errors', v_errors);
  end if;

  insert into public.exam_marks (exam_id, student_id, subject_id, marks, grade, is_absent, entered_by, updated_at)
  select p_exam_id,
         (item ->> 'student_id')::uuid,
         (item ->> 'subject_id')::uuid,
         nullif(item ->> 'marks', '')::numeric,
         nullif(item ->> 'grade', ''),
         (item ->> 'absent')::boolean,
         private.report_caller_email(),
         now()
    from jsonb_array_elements(v_clean) item
  on conflict (exam_id, student_id, subject_id) do update
    set marks = excluded.marks,
        grade = excluded.grade,
        is_absent = excluded.is_absent,
        entered_by = excluded.entered_by,
        updated_at = now();
  get diagnostics v_saved = row_count;

  insert into public.exam_publications (exam_id, class_name, section, status)
  values (p_exam_id, p_class, p_section, 'DRAFT')
  on conflict (exam_id, class_name, section) do update set updated_at = now();

  return jsonb_build_object('success', true, 'saved', v_saved);
end
$function$;

create or replace function public.report_card_submit(
  p_exam_id uuid,
  p_class text,
  p_section text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_status text;
  v_missing integer;
begin
  if auth.uid() is null
     or not (coalesce(private.is_admin(), false) or private.report_is_class_teacher(p_class, p_section)) then
    raise exception 'Only the class teacher can submit marks for this class' using errcode = '42501';
  end if;

  select status into v_status
    from public.exam_publications
   where exam_id = p_exam_id and class_name = p_class and section = p_section;
  if v_status in ('SUBMITTED', 'APPROVED') then
    return jsonb_build_object('success', false, 'message', 'Already ' || lower(v_status) || '.');
  end if;

  select count(*) into v_missing
    from public.student_roster r
    join public.exam_class_subjects c
      on c.exam_id = p_exam_id and c.class_name = r.class_name and c.section = r.section and c.active
    left join public.exam_marks m
      on m.exam_id = p_exam_id and m.student_id = r.id and m.subject_id = c.subject_id
   where r.school_code = 'ashiana'
     and r.class_name = p_class and r.section = p_section
     and upper(coalesce(r.status, '')) = 'ACTIVE'
     and (m.id is null or (m.marks is null and m.grade is null and not m.is_absent));
  if v_missing > 0 then
    return jsonb_build_object('success', false, 'message', v_missing || ' marks or grades are still empty. Complete every subject before submission.');
  end if;

  insert into public.exam_publications (exam_id, class_name, section, status, submitted_by, submitted_at, review_note, updated_at)
  values (p_exam_id, p_class, p_section, 'SUBMITTED', private.report_caller_email(), now(), null, now())
  on conflict (exam_id, class_name, section) do update
    set status = 'SUBMITTED', submitted_by = excluded.submitted_by, submitted_at = now(), review_note = null, updated_at = now();

  return jsonb_build_object('success', true, 'status', 'SUBMITTED');
end
$function$;

create or replace function public.student_report_cards_by_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student uuid;
  v_roster public.student_roster%rowtype;
begin
  v_student := public.student_session_student_id(p_token);
  if v_student is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  select * into v_roster
    from public.student_roster
   where id = v_student and school_code = 'ashiana' and upper(coalesce(status, '')) = 'ACTIVE';
  if not found then return jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND'); end if;

  return jsonb_build_object(
    'success', true,
    'student_name', v_roster.student_name,
    'class_name', v_roster.class_name,
    'section', v_roster.section,
    'roll_no', v_roster.roll_no,
    'cards', coalesce((
      select jsonb_agg(card order by card ->> 'academic_session' desc, card ->> 'exam_header', card ->> 'exam_type')
        from (
          select jsonb_build_object(
            'exam_id', e.id,
            'exam_name', e.exam_name,
            'exam_type', e.exam_type,
            'exam_header', e.exam_header,
            'academic_session', a.label,
            'published_at', p.reviewed_at,
            'report_card_format', coalesce((
              select max(c.report_card_format) from public.exam_class_subjects c
               where c.exam_id = e.id and c.class_name = v_roster.class_name and c.section = v_roster.section and c.active
            ), 'class_specific'),
            'subjects', totals.subjects,
            'total', totals.total,
            'max_total', totals.max_total,
            'percentage', totals.percentage,
            'grade', private.report_grade(totals.percentage)
          ) as card
            from public.exam_publications p
            join public.school_exams e on e.id = p.exam_id
            join public.academic_sessions a on a.id = e.academic_session_id
            cross join lateral (
              select jsonb_agg(jsonb_build_object(
                       'subject_id', s.id,
                       'code', s.subject_code,
                       'name', s.subject_name,
                       'grading_mode', c.grading_mode,
                       'grade_only', c.grading_mode = 'grade',
                       'marks', m.marks,
                       'grade', case
                         when c.grading_mode = 'grade' then m.grade
                         when m.marks is null then null
                         else private.report_grade(round(m.marks * 100 / nullif(c.max_marks, 0), 2))
                       end,
                       'absent', coalesce(m.is_absent, false),
                       'max_marks', c.max_marks
                     ) order by case when c.grading_mode = 'grade' then 1 else 0 end, s.subject_name) as subjects,
                     coalesce(sum(case when c.grading_mode = 'marks' then m.marks else 0 end), 0) as total,
                     coalesce(sum(case when c.grading_mode = 'marks' then c.max_marks else 0 end), 0) as max_total,
                     case when coalesce(sum(case when c.grading_mode = 'marks' then c.max_marks else 0 end), 0) > 0
                          then round(coalesce(sum(case when c.grading_mode = 'marks' then m.marks else 0 end), 0) * 100 /
                               sum(case when c.grading_mode = 'marks' then c.max_marks else 0 end), 2)
                     end as percentage
                from public.exam_class_subjects c
                join public.school_subjects s on s.id = c.subject_id
                left join public.exam_marks m
                  on m.exam_id = c.exam_id and m.subject_id = c.subject_id and m.student_id = v_student
               where c.exam_id = e.id and c.class_name = v_roster.class_name and c.section = v_roster.section and c.active
            ) totals
           where p.class_name = v_roster.class_name
             and p.section = v_roster.section
             and p.status = 'APPROVED'
        ) approved_cards
    ), '[]'::jsonb)
  );
end
$function$;

notify pgrst, 'reload schema';
