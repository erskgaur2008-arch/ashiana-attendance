-- Security Phase 1: harden public authentication and SECURITY DEFINER functions.
-- No product behavior changes are intended beyond rate limiting repeated student
-- credential attempts and removing unnecessary anonymous RPC execution.

create table if not exists private.student_login_rate_limits (
  login_key text primary key,
  window_started_at timestamptz not null default now(),
  attempt_count integer not null default 0,
  updated_at timestamptz not null default now()
);

revoke all on table private.student_login_rate_limits from public, anon, authenticated;

create or replace function public.consume_student_login_attempt(
  p_login_key text,
  p_max_attempts integer default 6,
  p_window_seconds integer default 600
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_key text;
  v_row private.student_login_rate_limits%rowtype;
  v_now timestamptz := clock_timestamp();
  v_retry integer;
begin
  v_key := encode(
    extensions.digest(coalesce(trim(p_login_key), ''), 'sha256'),
    'hex'
  );

  if coalesce(trim(p_login_key), '') = '' then
    return jsonb_build_object('allowed', false, 'retry_after_seconds', p_window_seconds);
  end if;

  p_max_attempts := greatest(coalesce(p_max_attempts, 6), 1);
  p_window_seconds := greatest(coalesce(p_window_seconds, 600), 1);

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(v_key)
  );

  select *
    into v_row
    from private.student_login_rate_limits
   where login_key = v_key
   for update;

  if not found then
    insert into private.student_login_rate_limits(
      login_key, window_started_at, attempt_count, updated_at
    )
    values(v_key, v_now, 1, v_now);

    return jsonb_build_object(
      'allowed', true,
      'attempts_remaining', greatest(p_max_attempts - 1, 0)
    );
  end if;

  if v_row.window_started_at + make_interval(secs => p_window_seconds) <= v_now then
    update private.student_login_rate_limits
       set window_started_at = v_now,
           attempt_count = 1,
           updated_at = v_now
     where login_key = v_key;

    return jsonb_build_object(
      'allowed', true,
      'attempts_remaining', greatest(p_max_attempts - 1, 0)
    );
  end if;

  if v_row.attempt_count >= p_max_attempts then
    v_retry := greatest(
      1,
      ceil(extract(epoch from (
        v_row.window_started_at + make_interval(secs => p_window_seconds) - v_now
      )))::integer
    );

    update private.student_login_rate_limits
       set updated_at = v_now
     where login_key = v_key;

    return jsonb_build_object(
      'allowed', false,
      'retry_after_seconds', v_retry
    );
  end if;

  update private.student_login_rate_limits
     set attempt_count = attempt_count + 1,
         updated_at = v_now
   where login_key = v_key;

  return jsonb_build_object(
    'allowed', true,
    'attempts_remaining', greatest(p_max_attempts - v_row.attempt_count - 1, 0)
  );
end;
$function$;

create or replace function public.clear_student_login_attempt(p_login_key text)
returns void
language sql
security definer
set search_path = ''
as $function$
  delete from private.student_login_rate_limits
   where login_key = encode(
     extensions.digest(coalesce(trim(p_login_key), ''), 'sha256'),
     'hex'
   );
$function$;

revoke all on function public.consume_student_login_attempt(text, integer, integer) from public, anon, authenticated;
revoke all on function public.clear_student_login_attempt(text) from public, anon, authenticated;
grant execute on function public.consume_student_login_attempt(text, integer, integer) to postgres, service_role;
grant execute on function public.clear_student_login_attempt(text) to postgres, service_role;

-- Anonymous execution is not useful here because the function itself requires
-- a real authenticated teacher session.
revoke execute on function public.mark_student_attendance_by_qr(text, text) from anon;

-- Pin every SECURITY DEFINER function in this phase to an empty search_path.
alter function private.is_admin() set search_path = '';
alter function public.enforce_staff_valid_thru_admin_only() set search_path = '';
alter function public.mark_student_attendance_by_qr(text, text) set search_path = '';
alter function public.student_login(text, text, text) set search_path = '';
alter function public.student_portal_bundle(text, text) set search_path = '';
alter function public.student_submit_leave(text, text, date, date, text) set search_path = '';
alter function public.teacher_delete_student(uuid) set search_path = '';
alter function public.verify_staff_pin_internal(text, text) set search_path = '';
alter function public.record_attendance_punch_service(text, date, text, text, text) set search_path = '';

-- Student login: rate-limit failed credential attempts per enrollment key.
create or replace function public.student_login(
  p_school_code text,
  p_enroll_no text,
  p_dob_password text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  s public.student_roster%rowtype;
  dob_date date;
  rate jsonb;
  login_key text := lower(coalesce(p_school_code, '')) || ':' || upper(trim(coalesce(p_enroll_no, '')));
begin
  rate := public.consume_student_login_attempt(login_key, 6, 600);
  if coalesce((rate->>'allowed')::boolean, false) = false then
    return jsonb_build_object(
      'success', false,
      'code', 'RATE_LIMIT',
      'retry_after_seconds', coalesce((rate->>'retry_after_seconds')::integer, 600)
    );
  end if;

  if p_school_code is null or p_school_code <> 'ashiana' then
    return jsonb_build_object('success',false);
  end if;

  if p_enroll_no is null
     or length(trim(p_enroll_no))=0
     or p_dob_password !~ '^[0-9]{8}$' then
    return jsonb_build_object('success',false);
  end if;

  begin
    dob_date := make_date(
      substring(p_dob_password from 5 for 4)::int,
      substring(p_dob_password from 3 for 2)::int,
      substring(p_dob_password from 1 for 2)::int
    );
  exception when others then
    return jsonb_build_object('success',false);
  end;

  select * into s
  from public.student_roster
  where school_code='ashiana'
    and upper(enroll_no)=upper(trim(p_enroll_no))
    and status='ACTIVE'
    and dob=dob_date
  limit 1;

  if not found then
    return jsonb_build_object('success',false);
  end if;

  perform public.clear_student_login_attempt(login_key);

  return jsonb_build_object(
    'success',true,
    'student',jsonb_build_object(
      'id',s.id,'enroll_no',s.enroll_no,'student_name',s.student_name,
      'class_name',s.class_name,'section',s.section,'roll_no',s.roll_no,
      'gender',s.gender,'category',s.category,'status',s.status,'dob',s.dob,
      'mother_name',s.mother_name,'father_name',s.father_name,'address',s.address,
      'phone_number',s.phone_number,'photo_path',s.photo_path
    )
  );
end;
$function$;

revoke all on function public.student_login(text,text,text) from public;
grant execute on function public.student_login(text,text,text) to anon, authenticated;

-- Student portal bundle: same credential rate limit, cleared after success.
create or replace function public.student_portal_bundle(
  p_enroll_no text,
  p_dob_password text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  s public.student_roster%rowtype;
  d date;
  out jsonb;
  rate jsonb;
  login_key text := 'portal:' || upper(trim(coalesce(p_enroll_no, '')));
begin
  rate := public.consume_student_login_attempt(login_key, 6, 600);
  if coalesce((rate->>'allowed')::boolean, false) = false then
    return jsonb_build_object(
      'success', false,
      'code', 'RATE_LIMIT',
      'retry_after_seconds', coalesce((rate->>'retry_after_seconds')::integer, 600)
    );
  end if;

  if p_dob_password is null or p_dob_password !~ '^[0-9]{8}$' then
    return jsonb_build_object('success',false);
  end if;

  begin
    d := make_date(
      substring(p_dob_password from 5 for 4)::int,
      substring(p_dob_password from 3 for 2)::int,
      substring(p_dob_password from 1 for 2)::int
    );
  exception when others then
    return jsonb_build_object('success',false);
  end;

  select * into s
  from public.student_roster
  where school_code='ashiana'
    and upper(enroll_no)=upper(trim(p_enroll_no))
    and status='ACTIVE'
    and dob=d
  limit 1;

  if not found then
    return jsonb_build_object('success',false);
  end if;

  perform public.clear_student_login_attempt(login_key);

  out := jsonb_build_object(
    'success',true,
    'student',jsonb_build_object(
      'id',s.id,'enroll_no',s.enroll_no,'student_name',s.student_name,
      'class_name',s.class_name,'section',s.section,'roll_no',s.roll_no,
      'gender',s.gender,'category',s.category,'status',s.status,'dob',s.dob,
      'mother_name',s.mother_name,'father_name',s.father_name,'address',s.address,
      'phone_number',s.phone_number,'photo_path',s.photo_path
    ),
    'attendance',(select coalesce(jsonb_agg(to_jsonb(a) order by a.attendance_date desc),'[]'::jsonb) from public.student_attendance a where a.school_code='ashiana' and a.student_id=s.id),
    'notices',(select coalesce(jsonb_agg(to_jsonb(n) order by n.publish_at desc),'[]'::jsonb) from public.student_notices n where n.school_code='ashiana' and n.active and (n.class_name is null or n.class_name=s.class_name) and (n.section is null or n.section=s.section)),
    'homework',(select coalesce(jsonb_agg(to_jsonb(h) order by h.due_date nulls last,h.created_at desc),'[]'::jsonb) from public.student_homework h where h.school_code='ashiana' and h.active and h.class_name=s.class_name and h.section=s.section),
    'timetable',(select coalesce(jsonb_agg(to_jsonb(t) order by t.day_of_week,t.period_no),'[]'::jsonb) from public.student_timetable t where t.school_code='ashiana' and t.active and t.class_name=s.class_name and t.section=s.section),
    'leave_requests',(select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at desc),'[]'::jsonb) from public.student_leave_requests l where l.school_code='ashiana' and l.student_id=s.id),
    'report_cards',(select coalesce(jsonb_agg(to_jsonb(r) order by r.academic_year desc,r.term desc),'[]'::jsonb) from public.student_report_cards r where r.school_code='ashiana' and r.student_id=s.id and r.published),
    'calendar',(select coalesce(jsonb_agg(to_jsonb(c) order by c.event_date),'[]'::jsonb) from public.student_calendar_events c where c.school_code='ashiana' and c.active and (c.class_name is null or c.class_name=s.class_name) and (c.section is null or c.section=s.section))
  );

  return out;
end;
$function$;

revoke all on function public.student_portal_bundle(text,text) from public;
grant execute on function public.student_portal_bundle(text,text) to anon;

-- Student leave submission: rate-limit repeated credentialed requests.
create or replace function public.student_submit_leave(
  p_enroll_no text,
  p_dob_password text,
  p_from_date date,
  p_to_date date,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  s public.student_roster%rowtype;
  d date;
  assigned_email text;
  lid uuid;
  rate jsonb;
  login_key text := 'leave:' || upper(trim(coalesce(p_enroll_no, '')));
begin
  rate := public.consume_student_login_attempt(login_key, 6, 600);
  if coalesce((rate->>'allowed')::boolean, false) = false then
    return jsonb_build_object(
      'success', false,
      'code', 'RATE_LIMIT',
      'retry_after_seconds', coalesce((rate->>'retry_after_seconds')::integer, 600)
    );
  end if;

  begin
    d := make_date(
      substring(p_dob_password from 5 for 4)::int,
      substring(p_dob_password from 3 for 2)::int,
      substring(p_dob_password from 1 for 2)::int
    );
  exception when others then
    return jsonb_build_object('success',false,'message','Invalid DOB');
  end;

  select * into s
  from public.student_roster
  where school_code='ashiana'
    and upper(enroll_no)=upper(trim(p_enroll_no))
    and status='ACTIVE'
    and dob=d
  limit 1;

  if not found then
    return jsonb_build_object('success',false,'message','Invalid student login');
  end if;

  if p_from_date is null
     or p_to_date is null
     or p_to_date<p_from_date
     or coalesce(trim(p_reason),'')='' then
    return jsonb_build_object('success',false,'message','Complete leave details');
  end if;

  select teacher_email into assigned_email
  from public.student_class_assignments
  where school_code='ashiana'
    and class_name=s.class_name
    and section=s.section
    and active=true
  order by created_at desc
  limit 1;

  insert into public.student_leave_requests(
    school_code,student_id,from_date,to_date,reason,status,teacher_email
  )
  values(
    'ashiana',s.id,p_from_date,p_to_date,trim(p_reason),'PENDING',assigned_email
  )
  returning id into lid;

  perform public.clear_student_login_attempt(login_key);

  return jsonb_build_object('success',true,'id',lid);
end;
$function$;

revoke all on function public.student_submit_leave(text,text,date,date,text) from public;
grant execute on function public.student_submit_leave(text,text,date,date,text) to anon;

-- These functions already use fully-qualified table names; the only extra
-- unqualified extension call is gen_random_uuid(), so replace it explicitly.
create or replace function public.record_attendance_punch_service(
  p_staff_id text,
  p_attendance_date date,
  p_type text,
  p_timestamp text,
  p_method text default 'QR_PIN'
)
returns public.attendance_punches
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v public.attendance_punches;
  v_staff public.staff;
  v_latest public.attendance_punches;
  v_expected text;
begin
  if p_attendance_date is null then raise exception 'Attendance date required'; end if;
  if p_type not in ('IN','OUT') then raise exception 'Invalid punch type'; end if;

  select * into v_staff
  from public.staff
  where id=p_staff_id and status='ACTIVE'
  for update;

  if not found then raise exception 'Active staff record not found'; end if;

  select * into v_latest
  from public.attendance_punches
  where staff_id=p_staff_id and attendance_date=p_attendance_date
  order by created_at desc
  limit 1;

  if v_latest.id is not null
     and v_latest.created_at > now() - interval '30 seconds'
  then
    raise exception 'DUPLICATE_SCAN_WAIT_30_SECONDS';
  end if;

  v_expected := case
    when v_latest.id is null or v_latest.type='OUT' then 'IN'
    else 'OUT'
  end;

  if p_type <> v_expected then raise exception 'PUNCH_SEQUENCE_CONFLICT'; end if;

  insert into public.attendance_punches(
    id,staff_id,staff_name,emp_id,attendance_date,type,timestamp,method
  )
  values(
    extensions.gen_random_uuid()::text,
    v_staff.id,v_staff.name,v_staff.emp_id,p_attendance_date,
    p_type,p_timestamp,coalesce(nullif(p_method,''),'QR_PIN')
  )
  returning * into v;

  return v;
end;
$function$;

revoke execute on function public.record_attendance_punch_service(text,date,text,text,text) from public, anon, authenticated;
grant execute on function public.record_attendance_punch_service(text,date,text,text,text) to service_role;

notify pgrst, 'reload schema';
