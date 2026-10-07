-- Class Teacher student profile management.
-- Class Teachers may edit/delete only students in their actively assigned class/section.
-- Deleting a student intentionally deletes the complete student_roster row.
-- Existing foreign keys decide which related records cascade.

create or replace function public.teacher_update_student_profile(
  p_student_id uuid,
  p_student_name text,
  p_father_name text,
  p_mother_name text,
  p_dob date,
  p_phone_number text,
  p_address text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email','')));
  v_student public.student_roster%rowtype;
begin
  if v_email = '' then
    return jsonb_build_object('success',false,'code','AUTH_REQUIRED','message','Teacher authentication is required.');
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
      updated_at=now()
  where id=p_student_id;

  return jsonb_build_object('success',true,'message','Student information updated successfully.');
end;
$function$;

revoke all on function public.teacher_update_student_profile(uuid,text,text,text,date,text,text) from public;
grant execute on function public.teacher_update_student_profile(uuid,text,text,text,date,text,text) to authenticated;


create or replace function public.teacher_delete_student(
  p_student_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email','')));
  v_student public.student_roster%rowtype;
begin
  if v_email = '' then
    return jsonb_build_object('success',false,'code','AUTH_REQUIRED','message','Teacher authentication is required.');
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

  delete from public.student_roster where id=p_student_id;

  return jsonb_build_object(
    'success',true,
    'message','Student record deleted successfully.',
    'student_id',p_student_id
  );
end;
$function$;

revoke all on function public.teacher_delete_student(uuid) from public;
grant execute on function public.teacher_delete_student(uuid) to authenticated;
