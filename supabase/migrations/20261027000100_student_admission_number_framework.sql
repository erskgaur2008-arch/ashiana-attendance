-- Student admission-number framework for Ashiana Attendance.
-- Format: APS-YY-NNNN. The NNNN component reuses the existing numeric enroll_no.
-- This migration is intentionally additive; it does not alter authentication, attendance,
-- existing student IDs, or the retired report-card feature.

alter table public.student_roster
  add column if not exists registration_year integer,
  add column if not exists serial_number integer,
  add column if not exists admission_number text;

comment on column public.student_roster.registration_year is
  'Full admission year, e.g. 2026; displayed as YY in admission_number.';
comment on column public.student_roster.serial_number is
  'Numeric serial derived from the existing enroll_no; retained separately for structured queries.';
comment on column public.student_roster.admission_number is
  'Formatted internal registration number: APS-YY-NNNN.';

-- The final display identifier must never be duplicated.
create unique index if not exists student_roster_admission_number_uidx
  on public.student_roster (admission_number)
  where admission_number is not null;

-- Fast lookup and uniqueness guard for a school's admission-year serial batch.
create unique index if not exists student_roster_school_year_serial_uidx
  on public.student_roster (school_code, registration_year, serial_number)
  where registration_year is not null and serial_number is not null;

create index if not exists student_roster_school_registration_year_idx
  on public.student_roster (school_code, registration_year)
  where admission_number is null;

create or replace function public.sync_student_admission_number()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_serial integer;
begin
  -- New records default to the current calendar year unless the admin explicitly
  -- provides the actual admission year. Legacy bulk generation supplies the year.
  if tg_op = 'INSERT' and new.registration_year is null then
    new.registration_year := extract(year from now())::integer;
  end if;

  -- Enroll No is the authoritative serial component; do not reorder existing IDs.
  if coalesce(trim(new.enroll_no), '') ~ '^[0-9]{1,4}$' then
    v_serial := trim(new.enroll_no)::integer;
    if v_serial between 1 and 9999 then
      new.serial_number := v_serial;
    end if;
  elsif new.admission_number is null then
    -- Leave non-numeric enrollment IDs untouched; the bulk RPC will report them
    -- explicitly instead of silently generating a mismatched registration number.
    new.serial_number := null;
  end if;

  -- Generate once; later name/class/section edits do not change the identifier.
  if new.admission_number is null
     and new.registration_year between 2000 and 2199
     and new.serial_number between 1 and 9999 then
    new.admission_number :=
      'APS-' || lpad((new.registration_year % 100)::text, 2, '0')
      || '-' || lpad(new.serial_number::text, 4, '0');
  end if;

  return new;
end;
$function$;

drop trigger if exists student_roster_sync_admission_number on public.student_roster;
create trigger student_roster_sync_admission_number
before insert or update of enroll_no, registration_year, serial_number
on public.student_roster
for each row
execute function public.sync_student_admission_number();

-- Admin-only bulk backfill. Uses each student's existing Enroll No as NNNN,
-- and intentionally does not alphabetically renumber students or alter their IDs.
create or replace function public.admin_generate_student_admission_numbers(
  p_school_code text,
  p_registration_year integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_invalid_count integer;
  v_duplicate_count integer;
  v_updated_count integer;
begin
  if not coalesce(private.is_admin(), false) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;

  if p_school_code is null or lower(trim(p_school_code)) <> 'ashiana' then
    raise exception 'Unsupported school code' using errcode = '22023';
  end if;

  if p_registration_year < 2000 or p_registration_year > 2199 then
    raise exception 'Registration year must be a full year between 2000 and 2199'
      using errcode = '22023';
  end if;

  -- Serialize generation jobs for this school/year and avoid concurrent batches.
  perform pg_advisory_xact_lock(hashtext('student-admission-number'), hashtext(lower(trim(p_school_code)) || ':' || p_registration_year::text));

  -- Every unassigned student must have a usable numeric Enroll No for NNNN.
  select count(*) into v_invalid_count
  from public.student_roster s
  where lower(s.school_code) = lower(trim(p_school_code))
    and s.admission_number is null
    and (
      coalesce(trim(s.enroll_no), '') !~ '^[0-9]{1,4}$'
      or trim(s.enroll_no)::integer not between 1 and 9999
    );

  if v_invalid_count > 0 then
    raise exception '% unassigned student(s) have a non-numeric or out-of-range Enroll No. Fix those records before generation.', v_invalid_count
      using errcode = '22023';
  end if;

  -- Detect numeric collisions such as Enroll No "0012" and "12" before writes.
  select count(*) into v_duplicate_count
  from (
    select trim(s.enroll_no)::integer
    from public.student_roster s
    where lower(s.school_code) = lower(trim(p_school_code))
      and s.admission_number is null
    group by trim(s.enroll_no)::integer
    having count(*) > 1
  ) duplicates;

  if v_duplicate_count > 0 then
    raise exception 'Duplicate numeric Enroll No values exist. Resolve duplicates before generation.'
      using errcode = '23505';
  end if;

  update public.student_roster s
  set registration_year = p_registration_year,
      serial_number = trim(s.enroll_no)::integer,
      admission_number = 'APS-' || lpad((p_registration_year % 100)::text, 2, '0')
        || '-' || lpad(trim(s.enroll_no), 4, '0'),
      updated_at = now()
  where lower(s.school_code) = lower(trim(p_school_code))
    and s.admission_number is null;

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object(
    'success', true,
    'school_code', lower(trim(p_school_code)),
    'registration_year', p_registration_year,
    'generated_count', v_updated_count,
    'serial_source', 'existing enroll_no'
  );
end;
$function$;

revoke all on function public.admin_generate_student_admission_numbers(text, integer) from public, anon;
grant execute on function public.admin_generate_student_admission_numbers(text, integer) to authenticated;

notify pgrst, 'reload schema';
