-- Report-card marks and approval workflow, mirrored from the migration already
-- applied to Ashiana-Attendance-DB (20261027042425). This file restores the
-- migration source to the repository; it should not be applied to production
-- again because that migration version is already present there.

create table if not exists public.exam_marks (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana' check (school_code = 'ashiana'),
  exam_id uuid not null references public.school_exams(id) on delete cascade,
  student_id uuid not null references public.student_roster(id) on delete cascade,
  subject_id uuid not null references public.school_subjects(id) on delete restrict,
  marks numeric check (marks is null or marks >= 0),
  is_absent boolean not null default false,
  entered_by text,
  updated_at timestamptz not null default now(),
  check (not (is_absent and marks is not null)),
  unique (exam_id, student_id, subject_id)
);

create index if not exists exam_marks_exam_student
  on public.exam_marks (exam_id, student_id);

create table if not exists public.exam_publications (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana' check (school_code = 'ashiana'),
  exam_id uuid not null references public.school_exams(id) on delete cascade,
  class_name text not null,
  section text not null,
  status text not null default 'DRAFT'
    check (status in ('DRAFT', 'SUBMITTED', 'APPROVED', 'REJECTED')),
  submitted_by text,
  submitted_at timestamptz,
  reviewed_by text,
  reviewed_at timestamptz,
  review_note text,
  updated_at timestamptz not null default now(),
  unique (exam_id, class_name, section)
);

alter table public.exam_marks enable row level security;
alter table public.exam_publications enable row level security;
revoke all on table public.exam_marks, public.exam_publications from anon, authenticated;
grant all on table public.exam_marks, public.exam_publications to service_role;

create or replace function private.report_caller_email()
returns text
language sql
stable
security definer
set search_path = ''
as $function$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$function$;

create or replace function private.report_is_class_teacher(p_class text, p_section text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
      from public.student_class_assignments a
     where a.school_code = 'ashiana'
       and a.active is true
       and a.class_name = p_class
       and a.section = p_section
       and lower(a.teacher_email) = private.report_caller_email()
       and private.report_caller_email() <> ''
  )
$function$;

create or replace function private.report_grade(p_percent numeric)
returns text
language sql
immutable
set search_path = ''
as $function$
  select case
    when p_percent is null then null
    when p_percent >= 91 then 'A1'
    when p_percent >= 81 then 'A2'
    when p_percent >= 71 then 'B1'
    when p_percent >= 61 then 'B2'
    when p_percent >= 51 then 'C1'
    when p_percent >= 41 then 'C2'
    when p_percent >= 33 then 'D'
    else 'E'
  end
$function$;

revoke all on function private.report_caller_email() from public;
revoke all on function private.report_is_class_teacher(text, text) from public;
revoke all on function private.report_grade(numeric) from public;

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
      'class_name', x.class_name,
      'section', x.section,
      'status', coalesce(p.status, 'DRAFT'),
      'is_class_teacher', private.report_is_class_teacher(x.class_name, x.section)
    ) order by x.exam_name, x.class_name, x.section)
    from (
      select distinct e.id as exam_id, e.exam_name, c.class_name, c.section
        from public.school_exams e
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
begin
  if auth.uid() is null
     or not (v_admin or private.report_is_class_teacher(p_class, p_section)) then
    raise exception 'Not allowed for this class' using errcode = '42501';
  end if;

  select * into v_publication
    from public.exam_publications
   where exam_id = p_exam_id
     and class_name = p_class
     and section = p_section;

  return jsonb_build_object(
    'status', coalesce(v_publication.status, 'DRAFT'),
    'review_note', v_publication.review_note,
    'subjects', coalesce((
      select jsonb_agg(jsonb_build_object(
        'subject_id', s.id,
        'code', s.subject_code,
        'name', s.subject_name,
        'max_marks', c.max_marks
      ) order by s.subject_name)
        from public.exam_class_subjects c
        join public.school_subjects s on s.id = c.subject_id
       where c.exam_id = p_exam_id
         and c.class_name = p_class
         and c.section = p_section
         and c.active
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
        'absent', m.is_absent
      ))
        from public.exam_marks m
        join public.student_roster r on r.id = m.student_id
       where m.exam_id = p_exam_id
         and r.class_name = p_class
         and r.section = p_section
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
  v_marks numeric;
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
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then
    raise exception 'Invalid marks upload';
  end if;

  select status into v_status
    from public.exam_publications
   where exam_id = p_exam_id
     and class_name = p_class
     and section = p_section;
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
    select s.id, c.max_marks into v_subject, v_max
      from public.exam_class_subjects c
      join public.school_subjects s on s.id = c.subject_id
     where c.exam_id = p_exam_id
       and c.class_name = p_class
       and c.section = p_section
       and c.active
       and upper(btrim(s.subject_code)) = upper(btrim(coalesce(r ->> 'subject_code', '')));

    v_raw := nullif(btrim(coalesce(r ->> 'marks', '')), '');
    v_absent := coalesce((r ->> 'absent')::boolean, false);
    v_marks := null;
    if v_student is null then
      v_errors := v_errors || jsonb_build_object(
        'row', v_row,
        'error', 'Student ' || coalesce(r ->> 'enroll_no', '?') || ' is not in this class'
      );
    elsif v_subject is null then
      v_errors := v_errors || jsonb_build_object(
        'row', v_row,
        'error', 'Subject ' || coalesce(r ->> 'subject_code', '?') || ' is not part of this exam'
      );
    else
      if v_raw is not null and not v_absent then
        if v_raw !~ '^[0-9]{1,5}(\.[0-9]{1,2})?$' then
          v_errors := v_errors || jsonb_build_object(
            'row', v_row,
            'error', 'Invalid marks "' || v_raw || '" for ' || (r ->> 'enroll_no')
          );
          continue;
        end if;
        v_marks := v_raw::numeric;
        if v_marks > v_max then
          v_errors := v_errors || jsonb_build_object(
            'row', v_row,
            'error', 'Marks ' || v_marks || ' exceed maximum ' || v_max || ' (' || (r ->> 'enroll_no') || ')'
          );
          continue;
        end if;
      end if;
      v_clean := v_clean || jsonb_build_object(
        'student_id', v_student,
        'subject_id', v_subject,
        'marks', v_marks,
        'absent', v_absent
      );
    end if;
  end loop;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object(
      'success', false,
      'message', 'Nothing was saved. Fix the rows below and upload again.',
      'errors', v_errors
    );
  end if;

  insert into public.exam_marks (exam_id, student_id, subject_id, marks, is_absent, entered_by, updated_at)
  select p_exam_id,
         (item ->> 'student_id')::uuid,
         (item ->> 'subject_id')::uuid,
         (item ->> 'marks')::numeric,
         (item ->> 'absent')::boolean,
         private.report_caller_email(),
         now()
    from jsonb_array_elements(v_clean) item
  on conflict (exam_id, student_id, subject_id) do update
    set marks = excluded.marks,
        is_absent = excluded.is_absent,
        entered_by = excluded.entered_by,
        updated_at = now();
  get diagnostics v_saved = row_count;

  insert into public.exam_publications (exam_id, class_name, section, status)
  values (p_exam_id, p_class, p_section, 'DRAFT')
  on conflict (exam_id, class_name, section) do update
    set updated_at = now();

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
    raise exception 'Only the class teacher can submit marks' using errcode = '42501';
  end if;

  select status into v_status
    from public.exam_publications
   where exam_id = p_exam_id
     and class_name = p_class
     and section = p_section;
  if v_status in ('SUBMITTED', 'APPROVED') then
    return jsonb_build_object('success', false, 'message', 'Already ' || lower(v_status) || '.');
  end if;

  select count(*) into v_missing
    from public.student_roster r
    join public.exam_class_subjects c
      on c.exam_id = p_exam_id
     and c.class_name = r.class_name
     and c.section = r.section
     and c.active
    left join public.exam_marks m
      on m.exam_id = p_exam_id
     and m.student_id = r.id
     and m.subject_id = c.subject_id
   where r.school_code = 'ashiana'
     and r.class_name = p_class
     and r.section = p_section
     and upper(coalesce(r.status, '')) = 'ACTIVE'
     and (m.id is null or (m.marks is null and not m.is_absent));
  if v_missing > 0 then
    return jsonb_build_object(
      'success', false,
      'message', v_missing || ' marks are still empty. Enter a mark or AB (absent) for every student and subject.'
    );
  end if;

  insert into public.exam_publications (
    exam_id, class_name, section, status, submitted_by, submitted_at, review_note, updated_at
  )
  values (
    p_exam_id, p_class, p_section, 'SUBMITTED', private.report_caller_email(), now(), null, now()
  )
  on conflict (exam_id, class_name, section) do update
    set status = 'SUBMITTED',
        submitted_by = excluded.submitted_by,
        submitted_at = now(),
        review_note = null,
        updated_at = now();

  return jsonb_build_object('success', true, 'status', 'SUBMITTED');
end
$function$;

create or replace function public.report_card_admin_queue()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not coalesce(private.is_admin(), false) then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'exam_id', p.exam_id,
      'exam_name', e.exam_name,
      'class_name', p.class_name,
      'section', p.section,
      'status', p.status,
      'submitted_by', p.submitted_by,
      'submitted_at', p.submitted_at,
      'reviewed_by', p.reviewed_by,
      'reviewed_at', p.reviewed_at,
      'review_note', p.review_note
    ) order by (p.status = 'SUBMITTED') desc, p.submitted_at desc nulls last)
      from public.exam_publications p
      join public.school_exams e on e.id = p.exam_id
     where p.status in ('SUBMITTED', 'APPROVED', 'REJECTED')
  ), '[]'::jsonb);
end
$function$;

create or replace function public.report_card_admin_review(
  p_exam_id uuid,
  p_class text,
  p_section text,
  p_approve boolean,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_status text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null or not coalesce(private.is_admin(), false) then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  select status into v_status
    from public.exam_publications
   where exam_id = p_exam_id
     and class_name = p_class
     and section = p_section
   for update;
  if v_status is null or v_status not in ('SUBMITTED', 'APPROVED') then
    return jsonb_build_object('success', false, 'message', 'Nothing to review for this class.');
  end if;
  if not p_approve and v_note is null then
    return jsonb_build_object('success', false, 'message', 'Add a note so the teacher knows what to correct.');
  end if;

  update public.exam_publications
     set status = case when p_approve then 'APPROVED' else 'REJECTED' end,
         reviewed_by = private.report_caller_email(),
         reviewed_at = now(),
         review_note = left(v_note, 500),
         updated_at = now()
   where exam_id = p_exam_id
     and class_name = p_class
     and section = p_section;

  return jsonb_build_object(
    'success', true,
    'status', case when p_approve then 'APPROVED' else 'REJECTED' end
  );
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
   where id = v_student
     and school_code = 'ashiana'
     and upper(coalesce(status, '')) = 'ACTIVE';
  if not found then
    return jsonb_build_object('success', false, 'code', 'STUDENT_NOT_FOUND');
  end if;

  return jsonb_build_object(
    'success', true,
    'student_name', v_roster.student_name,
    'class_name', v_roster.class_name,
    'section', v_roster.section,
    'roll_no', v_roster.roll_no,
    'cards', coalesce((
      select jsonb_agg(card order by card ->> 'exam_name')
        from (
          select jsonb_build_object(
            'exam_id', e.id,
            'exam_name', e.exam_name,
            'exam_header', e.exam_header,
            'published_at', p.reviewed_at,
            'subjects', totals.subjects,
            'total', totals.total,
            'max_total', totals.max_total,
            'percentage', totals.percentage,
            'grade', private.report_grade(totals.percentage)
          ) as card
            from public.exam_publications p
            join public.school_exams e on e.id = p.exam_id
            cross join lateral (
              select jsonb_agg(jsonb_build_object(
                       'name', sj.subject_name,
                       'marks', m.marks,
                       'absent', m.is_absent,
                       'max_marks', c.max_marks,
                       'grade', private.report_grade(
                         case when m.marks is null then null
                              else round(m.marks * 100 / c.max_marks, 2)
                         end
                       )
                     ) order by sj.subject_name) as subjects,
                     coalesce(sum(m.marks), 0) as total,
                     coalesce(sum(c.max_marks), 0) as max_total,
                     case when coalesce(sum(c.max_marks), 0) > 0
                          then round(coalesce(sum(m.marks), 0) * 100 / sum(c.max_marks), 2)
                     end as percentage
                from public.exam_class_subjects c
                join public.school_subjects sj on sj.id = c.subject_id
                left join public.exam_marks m
                  on m.exam_id = c.exam_id
                 and m.subject_id = c.subject_id
                 and m.student_id = v_student
               where c.exam_id = e.id
                 and c.class_name = v_roster.class_name
                 and c.section = v_roster.section
                 and c.active
            ) totals
           where p.class_name = v_roster.class_name
             and p.section = v_roster.section
             and p.status = 'APPROVED'
        ) approved_cards
    ), '[]'::jsonb)
  );
end
$function$;

revoke all on function public.report_card_exam_options() from public, anon;
revoke all on function public.report_card_sheet(uuid, text, text) from public, anon;
revoke all on function public.report_card_save_marks(uuid, text, text, jsonb) from public, anon;
revoke all on function public.report_card_submit(uuid, text, text) from public, anon;
revoke all on function public.report_card_admin_queue() from public, anon;
revoke all on function public.report_card_admin_review(uuid, text, text, boolean, text) from public, anon;
revoke all on function public.student_report_cards_by_session(text) from public, authenticated;
grant execute on function public.report_card_exam_options() to authenticated;
grant execute on function public.report_card_sheet(uuid, text, text) to authenticated;
grant execute on function public.report_card_save_marks(uuid, text, text, jsonb) to authenticated;
grant execute on function public.report_card_submit(uuid, text, text) to authenticated;
grant execute on function public.report_card_admin_queue() to authenticated;
grant execute on function public.report_card_admin_review(uuid, text, text, boolean, text) to authenticated;
grant execute on function public.student_report_cards_by_session(text) to anon;

notify pgrst, 'reload schema';
