-- Student admission numbers: APS-YY-NNNN (YY = academic admission year, NNNN = Enroll No / serial).
-- Additive. Enroll No stays unchanged (it is the student login id, QR value and photo key).

alter table public.student_roster
  add column if not exists registration_year smallint,
  add column if not exists serial_number smallint,
  add column if not exists admission_number text;

alter table public.student_roster drop constraint if exists student_roster_serial_chk;
alter table public.student_roster add constraint student_roster_serial_chk
  check (serial_number is null or serial_number between 1 and 9999);
alter table public.student_roster drop constraint if exists student_roster_admission_format_chk;
alter table public.student_roster add constraint student_roster_admission_format_chk
  check (admission_number is null or admission_number ~ '^APS-[0-9]{2}-[0-9]{4}$');

-- Indexes: final string unique; one serial per school per year (the real duplicate guard).
create unique index if not exists student_roster_admission_number_uidx
  on public.student_roster (admission_number);
create unique index if not exists student_roster_school_year_serial_uidx
  on public.student_roster (school_code, registration_year, serial_number);

-- Per school+year counter, locked with FOR UPDATE so concurrent inserts never share a number.
create table if not exists public.admission_serial_counters (
  school_code text not null default 'ashiana',
  registration_year smallint not null,
  last_serial integer not null default 0,
  primary key (school_code, registration_year)
);
alter table public.admission_serial_counters enable row level security;
revoke all on public.admission_serial_counters from public, anon, authenticated;

-- Academic admission year: from the active academic session (e.g. 2026-27 -> 2026),
-- otherwise April-March school year in India.
create or replace function private.admission_default_year()
returns smallint language sql stable security definer set search_path = '' as
$$
  select coalesce(
    (select left(label, 4)::smallint from public.academic_sessions
      where school_code = 'ashiana' and is_active limit 1),
    (case when extract(month from (now() at time zone 'Asia/Kolkata')) >= 4
          then extract(year from (now() at time zone 'Asia/Kolkata'))
          else extract(year from (now() at time zone 'Asia/Kolkata')) - 1 end)::smallint)
$$;

-- Assign the next number to one row. Prefers Enroll No as NNNN; otherwise appends after the
-- current maximum. Never re-sorts or changes existing students.
create or replace function private.assign_admission_number(rec public.student_roster)
returns public.student_roster language plpgsql security definer set search_path = '' as
$$
declare v_year smallint; v_last int; v_max int; v_serial int;
begin
  v_year := coalesce(rec.registration_year, private.admission_default_year());
  insert into public.admission_serial_counters(school_code, registration_year)
  values (rec.school_code, v_year) on conflict do nothing;
  select last_serial into v_last from public.admission_serial_counters
   where school_code = rec.school_code and registration_year = v_year for update;   -- serialises writers
  select coalesce(max(serial_number), 0) into v_max from public.student_roster
   where school_code = rec.school_code and registration_year = v_year;
  if (case when coalesce(rec.enroll_no, '') ~ '^[0-9]{1,4}$' then rec.enroll_no::int else 0 end) > 0
     and not exists (select 1 from public.student_roster x
                      where x.school_code = rec.school_code and x.registration_year = v_year
                        and x.serial_number = rec.enroll_no::int and x.id is distinct from rec.id) then
    v_serial := rec.enroll_no::int;
  else
    v_serial := greatest(v_last, v_max) + 1;
  end if;
  if v_serial > 9999 then raise exception 'Admission serial exceeds 9999 for %', v_year; end if;
  update public.admission_serial_counters set last_serial = greatest(last_serial, v_serial)
   where school_code = rec.school_code and registration_year = v_year;
  rec.registration_year := v_year;
  rec.serial_number := v_serial;
  rec.admission_number := 'APS-' || lpad((v_year % 100)::text, 2, '0') || '-' || lpad(v_serial::text, 4, '0');
  return rec;
end $$;

-- Automatic numbering for every new student (mid-term joiners, bulk imports, manual adds).
create or replace function private.student_roster_admission_insert_trg()
returns trigger language plpgsql security definer set search_path = '' as
$$
begin
  -- An upsert that will update an existing Enroll No must not burn a number.
  if exists (select 1 from public.student_roster x where x.school_code = new.school_code and x.enroll_no = new.enroll_no) then
    return new;
  end if;
  if new.admission_number is null then new := private.assign_admission_number(new); end if;
  return new;
end $$;
drop trigger if exists student_roster_admission_trg on public.student_roster;
create trigger student_roster_admission_trg before insert on public.student_roster
  for each row execute function private.student_roster_admission_insert_trg();

-- Numbers are permanent. SECURITY INVOKER on purpose: current_user is the real API role here,
-- while the system functions above run as the owner and are therefore allowed to change them.
create or replace function private.student_roster_admission_guard_trg()
returns trigger language plpgsql security invoker set search_path = '' as
$$
begin
  if old.admission_number is not null
     and (new.admission_number, new.serial_number, new.registration_year)
         is distinct from (old.admission_number, old.serial_number, old.registration_year)
     and current_user not in ('postgres', 'service_role', 'supabase_admin') then
    new.admission_number := old.admission_number;
    new.serial_number := old.serial_number;
    new.registration_year := old.registration_year;
  end if;
  return new;
end $$;
drop trigger if exists student_roster_admission_guard on public.student_roster;
create trigger student_roster_admission_guard before update on public.student_roster
  for each row execute function private.student_roster_admission_guard_trg();

-- Admin bulk job: numbers every student that still has none. Enroll No first; students without a
-- usable Enroll No get the next serials in name order (student_name ASC, id ASC).
create or replace function public.admin_generate_admission_numbers(p_year smallint default null)
returns jsonb language plpgsql security definer set search_path = '' as
$$
declare v_year smallint := coalesce(p_year, private.admission_default_year()); r public.student_roster; n int := 0;
begin
  if auth.uid() is null or not coalesce(private.is_admin(), false) then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  insert into public.admission_serial_counters(school_code, registration_year)
  values ('ashiana', v_year) on conflict do nothing;
  perform 1 from public.admission_serial_counters where school_code = 'ashiana' and registration_year = v_year for update;
  -- Reserve every valid Enroll No first so fallback serials can never collide with them.
  update public.admission_serial_counters c set last_serial = greatest(c.last_serial, coalesce((
    select max(enroll_no::int) from public.student_roster
     where school_code = 'ashiana' and admission_number is null and enroll_no ~ '^[0-9]{1,4}$'), 0))
   where c.school_code = 'ashiana' and c.registration_year = v_year;
  for r in select * from public.student_roster
            where school_code = 'ashiana' and admission_number is null
            order by (enroll_no ~ '^[0-9]{1,4}$') desc, student_name asc, id asc
            for update loop
    r.registration_year := v_year;
    r := private.assign_admission_number(r);
    update public.student_roster set registration_year = r.registration_year,
           serial_number = r.serial_number, admission_number = r.admission_number where id = r.id;
    n := n + 1;
  end loop;
  return jsonb_build_object('success', true, 'assigned', n, 'year', v_year);
end $$;
revoke all on function public.admin_generate_admission_numbers(smallint) from public, anon;
grant execute on function public.admin_generate_admission_numbers(smallint) to authenticated;

-- One-time backfill: existing 1,410 students -> APS-26-<Enroll No> (owner decision: 26 for everyone).
update public.student_roster
   set registration_year = 2026, serial_number = enroll_no::int,
       admission_number = 'APS-26-' || lpad(enroll_no, 4, '0')
 where admission_number is null and (case when enroll_no ~ '^[0-9]{1,4}$' then enroll_no::int else 0 end) > 0;
insert into public.admission_serial_counters(school_code, registration_year, last_serial)
select 'ashiana', 2026, coalesce(max(serial_number), 0) from public.student_roster where registration_year = 2026
on conflict (school_code, registration_year) do update set last_serial = greatest(public.admission_serial_counters.last_serial, excluded.last_serial);

-- Return admission_number in the student login/portal payloads (textual patch, only if not yet present).
do $patch$
declare f text; def text;
begin
  foreach f in array array['student_login(text,text,text)', 'student_portal_bundle(text,text)', 'student_portal_data(uuid)'] loop
    def := pg_get_functiondef(('public.' || f)::regprocedure);
    if def not like '%admission_number%' and position('''photo_path'',s.photo_path' in def) > 0 then
      def := replace(def, '''photo_path'',s.photo_path', '''photo_path'',s.photo_path,''admission_number'',s.admission_number');
      execute def;
    end if;
  end loop;
end $patch$;
