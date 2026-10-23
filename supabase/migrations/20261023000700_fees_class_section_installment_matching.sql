-- Fees Management: match fee structures to roster class + section and populate installments.
-- Example: roster class_name='I', section='A' matches fee structure class_name='I-A'.
-- Backfill only missing installments for existing accounts; never alter payments or discounts.

create or replace function public.fee_admin_assign_student_account(
  p_academic_year_id uuid,
  p_student_id uuid
) returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_account uuid;
  v_class text;
  v_section text;
  v_school text;
  v_structure record;
  v_installment uuid;
begin
  if v_actor is null or not private.is_admin() then
    raise exception 'Admin permission required';
  end if;

  select s.class_name, s.section, s.school_code
    into v_class, v_section, v_school
  from public.student_roster s
  where s.id=p_student_id and s.status='ACTIVE';

  if not found or v_school <> 'ashiana' then
    raise exception 'Active Ashiana student not found';
  end if;

  if not exists (
    select 1 from public.fee_academic_years y
    where y.id=p_academic_year_id and y.school_code='ashiana'
  ) then
    raise exception 'Academic year not found';
  end if;

  insert into public.student_fee_accounts(school_code,academic_year_id,student_id,created_by)
  values ('ashiana',p_academic_year_id,p_student_id,v_actor)
  on conflict (academic_year_id,student_id) do update set school_code='ashiana'
  returning id into v_account;

  for v_structure in
    select fs.id, fs.amount_paise, fs.due_date
    from public.fee_structures fs
    where fs.academic_year_id=p_academic_year_id
      and fs.school_code='ashiana'
      and (
        fs.class_name=trim(coalesce(v_class,''))
        or fs.class_name=trim(coalesce(v_class,''))||'-'||trim(coalesce(v_section,''))
      )
  loop
    insert into public.fee_installments(
      fee_account_id,fee_structure_id,installment_no,amount_paise,due_date
    )
    values (
      v_account,v_structure.id,1,v_structure.amount_paise,
      coalesce(v_structure.due_date,(
        select y.starts_on from public.fee_academic_years y where y.id=p_academic_year_id
      ))
    )
    on conflict (fee_account_id,fee_structure_id,installment_no) do nothing
    returning id into v_installment;
  end loop;

  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
  values (
    'ashiana',v_actor,'STUDENT_FEE_ACCOUNT_ASSIGNED','student_fee_account',v_account,
    jsonb_build_object(
      'student_id',p_student_id,
      'academic_year_id',p_academic_year_id,
      'class_name',v_class,
      'section',v_section
    )
  );

  return v_account;
end;
$function$;

-- Safely backfill matching installments for existing accounts, including I-A roster records.
insert into public.fee_installments(
  fee_account_id,fee_structure_id,installment_no,amount_paise,due_date
)
select
  a.id, fs.id, 1, fs.amount_paise,
  coalesce(fs.due_date,y.starts_on)
from public.student_fee_accounts a
join public.student_roster s on s.id=a.student_id
join public.fee_academic_years y on y.id=a.academic_year_id
join public.fee_structures fs
  on fs.academic_year_id=a.academic_year_id
 and fs.school_code=a.school_code
 and (
   fs.class_name=trim(coalesce(s.class_name,''))
   or fs.class_name=trim(coalesce(s.class_name,''))||'-'||trim(coalesce(s.section,''))
 )
where a.school_code='ashiana'
  and s.school_code='ashiana'
  and s.status='ACTIVE'
on conflict (fee_account_id,fee_structure_id,installment_no) do nothing;
