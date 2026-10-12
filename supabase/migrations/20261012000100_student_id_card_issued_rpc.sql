-- Allow the RPC-authenticated student portal to check its own ID-card
-- issuance status without granting anon SELECT access to student_roster.
create or replace function public.student_id_card_issued(
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
  dob_date date;
  issued_at timestamptz;
begin
  if p_school_code is distinct from 'ashiana'
     or nullif(trim(coalesce(p_enroll_no, '')), '') is null
     or p_dob_password is null
     or p_dob_password !~ '^[0-9]{8}$' then
    return jsonb_build_object('success', false, 'issued', false);
  end if;

  begin
    dob_date := make_date(
      substring(p_dob_password from 5 for 4)::integer,
      substring(p_dob_password from 3 for 2)::integer,
      substring(p_dob_password from 1 for 2)::integer
    );
  exception when others then
    return jsonb_build_object('success', false, 'issued', false);
  end;

  select s.id_card_generated_at
    into issued_at
    from public.student_roster as s
   where s.school_code = 'ashiana'
     and upper(s.enroll_no) = upper(trim(p_enroll_no))
     and s.dob = dob_date
     and s.status = 'ACTIVE'
   limit 1;

  if not found then
    return jsonb_build_object('success', false, 'issued', false);
  end if;

  return jsonb_build_object(
    'success', true,
    'issued', issued_at is not null,
    'id_card_generated_at', issued_at
  );
end;
$function$;

revoke all on function public.student_id_card_issued(text, text, text) from public;
grant execute on function public.student_id_card_issued(text, text, text) to anon, authenticated;
