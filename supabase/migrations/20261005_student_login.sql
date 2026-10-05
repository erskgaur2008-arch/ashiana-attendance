-- Student login RPC: Admission No. + DOB password (DDMMYYYY).
create or replace function public.student_login(
  p_school_code text,
  p_enroll_no text,
  p_dob_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.student_roster%rowtype;
  dob_date date;
begin
  if p_school_code is null or p_school_code <> 'ashiana' then
    return jsonb_build_object('success',false);
  end if;
  if p_enroll_no is null or length(trim(p_enroll_no))=0 or p_dob_password !~ '^[0-9]{8}$' then
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
  select * into s from public.student_roster
  where school_code='ashiana'
    and upper(enroll_no)=upper(trim(p_enroll_no))
    and status='ACTIVE'
    and dob=dob_date
  limit 1;
  if not found then return jsonb_build_object('success',false); end if;
  return jsonb_build_object('success',true,'student',jsonb_build_object(
    'id',s.id,'enroll_no',s.enroll_no,'student_name',s.student_name,
    'class_name',s.class_name,'section',s.section,'roll_no',s.roll_no,
    'gender',s.gender,'category',s.category,'status',s.status,'dob',s.dob,
    'mother_name',s.mother_name,'father_name',s.father_name,'address',s.address,
    'phone_number',s.phone_number,'photo_path',s.photo_path
  ));
end;
$$;
revoke all on function public.student_login(text,text,text) from public;
grant execute on function public.student_login(text,text,text) to anon, authenticated;