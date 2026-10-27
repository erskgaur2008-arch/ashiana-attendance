-- Store the optional language once per academic session, class and section.
-- French/Punjabi remain ordinary marks subjects in exam_class_subjects.
create table if not exists public.report_card_optional_language_assignments (
  school_code text not null default 'ashiana' check (school_code = 'ashiana'),
  academic_session_id uuid not null references public.academic_sessions(id) on delete cascade,
  class_name text not null,
  section text not null,
  language text not null check (language in ('French', 'Punjabi')),
  created_by text,
  updated_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (school_code, academic_session_id, class_name, section),
  check (upper(regexp_replace(btrim(class_name), '^CLASS[[:space:]]+', '', 'i')) in ('IV', 'V', 'VI', 'VII', 'VIII')),
  check (length(btrim(section)) between 1 and 20)
);

create index if not exists report_card_optional_language_session_lookup
  on public.report_card_optional_language_assignments (school_code, academic_session_id, class_name, section);

alter table public.report_card_optional_language_assignments enable row level security;
revoke all on table public.report_card_optional_language_assignments from public, anon, authenticated;
grant all on table public.report_card_optional_language_assignments to service_role;

create or replace function private.report_card_sync_optional_languages(p_exam_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  -- Clear the seeded defaults for IV-VIII first. Only a saved section choice
  -- may make French or Punjabi active in that section's report card.
  update public.exam_class_subjects c
     set active = false,
         updated_at = now()
    from public.school_subjects s
    join public.school_exams e on e.id = p_exam_id
   where c.exam_id = p_exam_id
     and c.subject_id = s.id
     and c.school_code = 'ashiana'
     and upper(btrim(c.class_name)) in ('IV', 'V', 'VI', 'VII', 'VIII')
     and lower(btrim(s.subject_name)) in ('french', 'punjabi')
     and (
       (upper(btrim(c.class_name)) = 'IV' and e.exam_type in (
         'Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV',
         'Internal Assessment-I', 'Internal Assessment-II',
         'Internal Assessment-III', 'Internal Assessment-IV'
       ))
       or
       (upper(btrim(c.class_name)) in ('V', 'VI', 'VII', 'VIII') and e.exam_type in (
         'Unit Test-I', 'Unit Test-II', 'Internal Assessment-I',
         'Internal Assessment-II', 'Half-Yearly', 'Annual'
       ))
     );

  -- Add exactly the selected language to each relevant assessment. Both
  -- languages use marks mode and the same class-band assessment maxima.
  insert into public.exam_class_subjects (
    school_code, exam_id, academic_session_id, class_name, section,
    subject_id, max_marks, grading_mode, report_card_format,
    assessment_config, active, updated_at
  )
  select
    e.school_code,
    e.id,
    e.academic_session_id,
    a.class_name,
    a.section,
    s.id,
    case
      when upper(btrim(a.class_name)) = 'IV'
       and e.exam_type in ('Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV') then 35
      when upper(btrim(a.class_name)) = 'IV' then 15
      when e.exam_type in ('Unit Test-I', 'Unit Test-II') then 30
      when e.exam_type in ('Internal Assessment-I', 'Internal Assessment-II') then 20
      when e.exam_type in ('Half-Yearly', 'Annual') then 50
      else 100
    end,
    'marks',
    case
      when upper(btrim(a.class_name)) = 'IV' then 'class_iii_iv_result_cum_marksheet'
      when upper(btrim(a.class_name)) = 'V' then 'class_v_result_cum_marksheet'
      else 'class_vi_viii_result_cum_marksheet'
    end,
    jsonb_build_array(jsonb_build_object(
      'key', e.exam_type,
      'label', e.exam_name,
      'term', e.exam_header,
      'kind', 'marks'
    )),
    true,
    now()
  from public.school_exams e
  join public.report_card_optional_language_assignments a
    on a.school_code = e.school_code
   and a.academic_session_id = e.academic_session_id
  join public.school_subjects s
    on s.school_code = e.school_code
   and lower(btrim(s.subject_name)) = lower(btrim(a.language))
   and s.active
  where e.id = p_exam_id
    and e.school_code = 'ashiana'
    and upper(btrim(a.class_name)) in ('IV', 'V', 'VI', 'VII', 'VIII')
    and (
      (upper(btrim(a.class_name)) = 'IV' and e.exam_type in (
        'Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV',
        'Internal Assessment-I', 'Internal Assessment-II',
        'Internal Assessment-III', 'Internal Assessment-IV'
      ))
      or
      (upper(btrim(a.class_name)) in ('V', 'VI', 'VII', 'VIII') and e.exam_type in (
        'Unit Test-I', 'Unit Test-II', 'Internal Assessment-I',
        'Internal Assessment-II', 'Half-Yearly', 'Annual'
      ))
    )
  on conflict (exam_id, class_name, section, subject_id) do update
    set academic_session_id = excluded.academic_session_id,
        max_marks = excluded.max_marks,
        grading_mode = 'marks',
        report_card_format = excluded.report_card_format,
        assessment_config = excluded.assessment_config,
        active = true,
        updated_at = now();
end
$function$;

revoke all on function private.report_card_sync_optional_languages(uuid) from public, anon, authenticated;

create or replace function private.report_card_seed_exam_classes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.school_code = 'ashiana' then
    perform private.report_card_apply_exam_defaults(new.id);
    perform private.report_card_sync_optional_languages(new.id);
  end if;
  return new;
end
$function$;

revoke all on function private.report_card_seed_exam_classes() from public, anon, authenticated;

create or replace function private.report_card_require_optional_language()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.status = 'SUBMITTED'
     and upper(regexp_replace(btrim(new.class_name), '^CLASS[[:space:]]+', '', 'i')) in ('IV', 'V', 'VI', 'VII', 'VIII')
     and exists (
       select 1 from public.school_exams e
        where e.id = new.exam_id
          and e.school_code = 'ashiana'
          and (
            (upper(regexp_replace(btrim(new.class_name), '^CLASS[[:space:]]+', '', 'i')) = 'IV' and e.exam_type in (
              'Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV',
              'Internal Assessment-I', 'Internal Assessment-II',
              'Internal Assessment-III', 'Internal Assessment-IV'
            ))
            or
            (upper(regexp_replace(btrim(new.class_name), '^CLASS[[:space:]]+', '', 'i')) in ('V', 'VI', 'VII', 'VIII') and e.exam_type in (
              'Unit Test-I', 'Unit Test-II', 'Internal Assessment-I',
              'Internal Assessment-II', 'Half-Yearly', 'Annual'
            ))
          )
     )
     and not exists (
       select 1
         from public.school_exams e
         join public.report_card_optional_language_assignments a
           on a.school_code = e.school_code
          and a.academic_session_id = e.academic_session_id
          and a.class_name = new.class_name
          and a.section = new.section
        where e.id = new.exam_id
          and e.school_code = 'ashiana'
     ) then
    raise exception 'Admin must assign French or Punjabi for this class and section before report-card submission';
  end if;
  return new;
end
$function$;

revoke all on function private.report_card_require_optional_language() from public, anon, authenticated;
drop trigger if exists report_card_require_optional_language on public.exam_publications;
create trigger report_card_require_optional_language
  before insert or update of status on public.exam_publications
  for each row execute function private.report_card_require_optional_language();

do $backfill$
declare
  v_exam record;
begin
  for v_exam in select id from public.school_exams where school_code = 'ashiana'
  loop
    perform private.report_card_sync_optional_languages(v_exam.id);
  end loop;
end
$backfill$;

create or replace function public.report_card_optional_language_options()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not coalesce(private.is_admin(), false) then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'sessions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'label', a.label,
        'is_active', a.is_active
      ) order by a.is_active desc, a.starts_on desc, a.label desc)
      from public.academic_sessions a
      where a.school_code = 'ashiana'
    ), '[]'::jsonb),
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
        'class_name', x.class_name,
        'section', x.section
      ) order by x.class_name, x.section)
      from (
        select distinct r.class_name, r.section
        from public.student_roster r
        where r.school_code = 'ashiana'
          and upper(coalesce(r.status, '')) = 'ACTIVE'
          and upper(btrim(r.class_name)) in ('IV', 'V', 'VI', 'VII', 'VIII')
      ) x
    ), '[]'::jsonb),
    'assignments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'academic_session_id', a.academic_session_id,
        'session', s.label,
        'class_name', a.class_name,
        'section', a.section,
        'language', a.language
      ) order by s.starts_on desc, a.class_name, a.section)
      from public.report_card_optional_language_assignments a
      join public.academic_sessions s on s.id = a.academic_session_id
      where a.school_code = 'ashiana'
    ), '[]'::jsonb)
  );
end
$function$;

create or replace function public.report_card_set_optional_language(
  p_academic_session_id uuid,
  p_class text,
  p_section text,
  p_language text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_class_key text;
  v_class_name text;
  v_section text;
  v_language text;
  v_existing text;
  v_exam record;
begin
  if auth.uid() is null or not coalesce(private.is_admin(), false) then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  v_class_key := upper(regexp_replace(btrim(coalesce(p_class, '')), '^CLASS[[:space:]]+', '', 'i'));
  if v_class_key not in ('IV', 'V', 'VI', 'VII', 'VIII') then
    raise exception 'Choose a class from IV to VIII';
  end if;
  v_language := case lower(btrim(coalesce(p_language, '')))
    when 'french' then 'French'
    when 'punjabi' then 'Punjabi'
    else null
  end;
  if v_language is null then raise exception 'Choose French or Punjabi'; end if;

  if not exists (
    select 1 from public.academic_sessions a
     where a.id = p_academic_session_id and a.school_code = 'ashiana'
  ) then raise exception 'Academic session not found'; end if;

  select min(r.class_name), min(r.section)
    into v_class_name, v_section
    from public.student_roster r
   where r.school_code = 'ashiana'
     and upper(coalesce(r.status, '')) = 'ACTIVE'
     and upper(regexp_replace(btrim(r.class_name), '^CLASS[[:space:]]+', '', 'i')) = v_class_key
     and upper(btrim(r.section)) = upper(btrim(coalesce(p_section, '')));
  if v_class_name is null or v_section is null then
    raise exception 'No active students found for this class and section';
  end if;

  if not exists (
    select 1 from public.school_subjects s
     where s.school_code = 'ashiana'
       and lower(btrim(s.subject_name)) = lower(v_language)
       and s.active
  ) then raise exception '% is not active in school subjects', v_language; end if;

  select a.language into v_existing
    from public.report_card_optional_language_assignments a
   where a.school_code = 'ashiana'
     and a.academic_session_id = p_academic_session_id
     and a.class_name = v_class_name
     and a.section = v_section
   for update;

  if v_existing is distinct from v_language and exists (
    select 1
      from public.school_exams e
      join public.exam_publications p
        on p.exam_id = e.id and p.class_name = v_class_name and p.section = v_section
     where e.school_code = 'ashiana'
       and e.academic_session_id = p_academic_session_id
       and p.status in ('SUBMITTED', 'APPROVED')
       and (
         (v_class_key = 'IV' and e.exam_type in (
           'Unit Test-I', 'Unit Test-II', 'Unit Test-III', 'Unit Test-IV',
           'Internal Assessment-I', 'Internal Assessment-II',
           'Internal Assessment-III', 'Internal Assessment-IV'
         ))
         or
         (v_class_key in ('V', 'VI', 'VII', 'VIII') and e.exam_type in (
           'Unit Test-I', 'Unit Test-II', 'Internal Assessment-I',
           'Internal Assessment-II', 'Half-Yearly', 'Annual'
         ))
       )
  ) then
    raise exception 'This class has submitted or approved report cards in this session. Return them for correction before changing its language.';
  end if;

  insert into public.report_card_optional_language_assignments (
    school_code, academic_session_id, class_name, section,
    language, created_by, updated_by, updated_at
  ) values (
    'ashiana', p_academic_session_id, v_class_name, v_section,
    v_language, private.report_caller_email(), private.report_caller_email(), now()
  )
  on conflict (school_code, academic_session_id, class_name, section) do update
    set language = excluded.language,
        updated_by = excluded.updated_by,
        updated_at = now();

  for v_exam in
    select e.id from public.school_exams e
     where e.school_code = 'ashiana'
       and e.academic_session_id = p_academic_session_id
  loop
    perform private.report_card_sync_optional_languages(v_exam.id);
  end loop;

  return jsonb_build_object(
    'success', true,
    'academic_session_id', p_academic_session_id,
    'class_name', v_class_name,
    'section', v_section,
    'language', v_language
  );
end
$function$;

revoke all on function public.report_card_optional_language_options() from public, anon;
revoke all on function public.report_card_set_optional_language(uuid, text, text, text) from public, anon;
grant execute on function public.report_card_optional_language_options() to authenticated;
grant execute on function public.report_card_set_optional_language(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';
