-- Serialize student session leave submissions per student before checking overlap.
-- This protects the session-based RPC from simultaneous duplicate requests.
-- Apply and validate on EduPunch-Test first; do not deploy to production without approval.

create or replace function public.student_submit_leave_by_session(
  p_token text,
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
  v_student_id uuid;
  s public.student_roster%rowtype;
  v_result jsonb;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED', 'message', 'Please sign in again.');
  end if;

  select * into s from public.student_roster
   where id = v_student_id and school_code = 'ashiana'
     and lower(coalesce(status, '')) = 'active';
  if not found then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED', 'message', 'Please sign in again.');
  end if;

  if p_from_date is null or p_to_date is null or p_from_date > p_to_date
     or nullif(btrim(p_reason), '') is null then
    return jsonb_build_object('success', false, 'message', 'Please provide valid leave dates and reason.');
  end if;

  -- The transaction-scoped advisory lock makes overlap check + insert/delegation
  -- serial for this student, preventing two concurrent calls through this RPC
  -- from both observing an empty overlap set.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(s.id::text, 0)
  );

  if exists (
    select 1 from public.student_leave_requests l
     where l.student_id = s.id
       and upper(coalesce(l.status, '')) = 'PENDING'
       and l.from_date <= p_to_date
       and l.to_date >= p_from_date
  ) then
    return jsonb_build_object(
      'success', false,
      'message', 'A leave request for these dates is already pending.'
    );
  end if;

  if to_regprocedure('public.student_submit_leave(text,text,date,date,text)') is null then
    insert into public.student_leave_requests(school_code, student_id, enroll_no, from_date, to_date, reason, status)
    values ('ashiana', s.id, s.enroll_no, p_from_date, p_to_date, btrim(p_reason), 'PENDING');
    return jsonb_build_object('success', true, 'message', 'Leave request submitted.');
  end if;

  execute 'select public.student_submit_leave($1,$2,$3,$4,$5)'
    into v_result
    using s.enroll_no, to_char(s.dob, 'DDMMYYYY'), p_from_date, p_to_date, p_reason;
  return coalesce(v_result, jsonb_build_object('success', false, 'message', 'Leave request failed.'));
end;
$function$;

revoke all on function public.student_submit_leave_by_session(text,date,date,text) from public, authenticated;
grant execute on function public.student_submit_leave_by_session(text,date,date,text) to anon;
