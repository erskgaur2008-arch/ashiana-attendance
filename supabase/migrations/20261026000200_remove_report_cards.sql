-- Remove the retired report-card feature from the final database schema and student portal payload.
-- Historical migrations remain unchanged; this forward migration ensures fresh installs
-- also finish without the report-card table or payload field.

drop table if exists public.student_report_cards;

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
      'phone_number',s.phone_number,'mode_of_transport',s.mode_of_transport,
      'photo_path',s.photo_path
    ),
    'attendance',(select coalesce(jsonb_agg(to_jsonb(a) order by a.attendance_date desc),'[]'::jsonb) from public.student_attendance a where a.school_code='ashiana' and a.student_id=s.id),
    'notices',(select coalesce(jsonb_agg(to_jsonb(n) order by n.publish_at desc),'[]'::jsonb) from public.student_notices n where n.school_code='ashiana' and n.active and (n.class_name is null or n.class_name=s.class_name) and (n.section is null or n.section=s.section)),
    'homework',(select coalesce(jsonb_agg(to_jsonb(h) order by h.due_date nulls last,h.created_at desc),'[]'::jsonb) from public.student_homework h where h.school_code='ashiana' and h.active and h.class_name=s.class_name and h.section=s.section),
    'timetable',(select coalesce(jsonb_agg(to_jsonb(t) order by t.day_of_week,t.period_no),'[]'::jsonb) from public.student_timetable t where t.school_code='ashiana' and t.active and t.class_name=s.class_name and t.section=s.section),
    'leave_requests',(select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at desc),'[]'::jsonb) from public.student_leave_requests l where l.school_code='ashiana' and l.student_id=s.id),
    'calendar',(select coalesce(jsonb_agg(to_jsonb(c) order by c.event_date),'[]'::jsonb) from public.student_calendar_events c where c.school_code='ashiana' and c.active and (c.class_name is null or c.class_name=s.class_name) and (c.section is null or c.section=s.section))
  );

  return out;
end;
$function$;

revoke all on function public.student_portal_bundle(text,text) from public;
grant execute on function public.student_portal_bundle(text,text) to anon;

create or replace function public.student_portal_data(p_student_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  s public.student_roster%rowtype;
begin
  select * into s
  from public.student_roster
  where id=p_student_id and school_code='ashiana' and status='ACTIVE';
  if not found then return jsonb_build_object('success',false); end if;
  return jsonb_build_object(
    'success',true,
    'student',jsonb_build_object(
      'id',s.id,'enroll_no',s.enroll_no,'student_name',s.student_name,
      'class_name',s.class_name,'section',s.section,'roll_no',s.roll_no,
      'category',s.category,'dob',s.dob,'mother_name',s.mother_name,
      'father_name',s.father_name,'address',s.address,'phone_number',s.phone_number,
      'mode_of_transport',s.mode_of_transport,'photo_path',s.photo_path
    )
  );
end;
$function$;

revoke all on function public.student_portal_data(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
