-- Mark attendance notifications read only for the student represented by the secure session token.
create or replace function public.student_attendance_notifications_mark_read_by_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_student_id uuid;
  v_updated integer := 0;
begin
  v_student_id := public.student_session_student_id(p_token);
  if v_student_id is null then
    return jsonb_build_object('success', false, 'code', 'STUDENT_SESSION_EXPIRED');
  end if;

  update public.student_attendance_notifications
     set read_at = now()
   where student_id = v_student_id
     and school_code = 'ashiana'
     and read_at is null;
  get diagnostics v_updated = row_count;

  return jsonb_build_object('success', true, 'updated', v_updated);
end;
$function$;

revoke all on function public.student_attendance_notifications_mark_read_by_session(text) from public, authenticated;
grant execute on function public.student_attendance_notifications_mark_read_by_session(text) to anon;
