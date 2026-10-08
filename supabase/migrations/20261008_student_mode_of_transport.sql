-- Add student mode of transport managed by the Class Teacher.
-- The value is stored on student_roster and exposed through the existing
-- Class Teacher-only profile update RPC. No existing records are changed.

alter table public.student_roster
  add column if not exists mode_of_transport text;

comment on column public.student_roster.mode_of_transport is
  'Student transport mode selected by the Class Teacher for the assigned class/section.';

create or replace function public.teacher_update_student_profile(
  p_student_id uuid,
  p_student_name text,
  p_father_name text,
  p_mother_name text,
  p_dob date,
  p_phone_number text,
  p_address text,
  p_mode_of_transport text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email','')));
  v_student public.student_roster%rowtype;
  v_transport text := nullif(trim(coalesce(p_mode_of_transport,'')),'');
begin
  if v_email = '' then
    return jsonb_build_object('success',false,'code','AUTH_REQUIRED','message','Teacher authentication is required.');
  end if;

  if v_transport is not null
     and v_transport not in ('School Bus','Private Vehicle','Auto/Rickshaw','Walking','Other') then
    return jsonb_build_object('success',false,'code','INVALID_TRANSPORT','message','Invalid mode of transport.');
  end if;

  select s.* into v_student
  from public.student_roster s
  where s.id=p_student_id
    and s.school_code='ashiana'
    and exists (
      select 1
      from public.student_class_assignments a
      where a.school_code=s.school_code
        and lower(trim(a.teacher_email))=v_email
        and a.class_name=s.class_name
        and a.section=s.section
        and a.active=true
    )
  limit 1;

  if not found then
    return jsonb_build_object('success',false,'code','NOT_AUTHORIZED','message','You are not the Class Teacher for this student.');
  end if;

  if nullif(trim(coalesce(p_student_name,'')),'') is null then
    return jsonb_build_object('success',false,'code','INVALID_NAME','message','Student name is required.');
  end if;

  update public.student_roster
  set student_name=trim(p_student_name),
      father_name=nullif(trim(coalesce(p_father_name,'')),''),
      mother_name=nullif(trim(coalesce(p_mother_name,'')),''),
      dob=p_dob,
      phone_number=nullif(trim(coalesce(p_phone_number,'')),''),
      address=nullif(trim(coalesce(p_address,'')),''),
      mode_of_transport=v_transport,
      updated_at=now()
  where id=p_student_id;

  return jsonb_build_object('success',true,'message','Student information updated successfully.');
end;
$function$;

revoke all on function public.teacher_update_student_profile(uuid,text,text,text,date,text,text,text) from public, anon;
grant execute on function public.teacher_update_student_profile(uuid,text,text,text,date,text,text,text) to authenticated;

notify pgrst, 'reload schema';
