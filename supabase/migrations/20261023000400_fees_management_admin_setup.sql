-- Admin setup operations for Fees Management. Review before any production application.
begin;

create or replace function public.fee_admin_save_academic_year(
  p_label text, p_starts_on date, p_ends_on date, p_is_active boolean default false
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_id uuid;
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  if length(trim(coalesce(p_label,''))) not between 4 and 40 or p_starts_on > p_ends_on then
    raise exception 'Academic year label or date range is invalid';
  end if;
  if p_is_active then
    update public.fee_academic_years set is_active=false
    where school_code='ashiana' and is_active=true;
  end if;
  insert into public.fee_academic_years(school_code,label,starts_on,ends_on,is_active,created_by)
  values ('ashiana',trim(p_label),p_starts_on,p_ends_on,p_is_active,v_actor)
  on conflict (school_code,label) do update set
    starts_on=excluded.starts_on, ends_on=excluded.ends_on, is_active=excluded.is_active
  returning id into v_id;
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
  values ('ashiana',v_actor,'ACADEMIC_YEAR_SAVED','fee_academic_year',v_id,
    jsonb_build_object('label',trim(p_label),'starts_on',p_starts_on,'ends_on',p_ends_on,'is_active',p_is_active));
  return v_id;
end;
$$;

create or replace function public.fee_admin_save_structure(
  p_academic_year_id uuid, p_class_name text, p_fee_name text,
  p_amount_paise bigint, p_is_mandatory boolean default true, p_due_date date default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_id uuid;
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  if p_amount_paise is null or p_amount_paise < 0 or
     length(trim(coalesce(p_class_name,'')))=0 or length(trim(coalesce(p_fee_name,''))) not between 2 and 100 then
    raise exception 'Fee structure values are invalid';
  end if;
  if not exists(select 1 from public.fee_academic_years y where y.id=p_academic_year_id and y.school_code='ashiana') then
    raise exception 'Academic year not found';
  end if;
  insert into public.fee_structures(school_code,academic_year_id,class_name,fee_name,amount_paise,is_mandatory,due_date,created_by)
  values ('ashiana',p_academic_year_id,trim(p_class_name),trim(p_fee_name),p_amount_paise,p_is_mandatory,p_due_date,v_actor)
  on conflict (academic_year_id,class_name,fee_name) do update set
    amount_paise=excluded.amount_paise,is_mandatory=excluded.is_mandatory,due_date=excluded.due_date
  returning id into v_id;
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
  values ('ashiana',v_actor,'FEE_STRUCTURE_SAVED','fee_structure',v_id,
    jsonb_build_object('academic_year_id',p_academic_year_id,'class_name',trim(p_class_name),'fee_name',trim(p_fee_name),'amount_paise',p_amount_paise));
  return v_id;
end;
$$;

create or replace function public.fee_admin_assign_student_account(
  p_academic_year_id uuid, p_student_id uuid
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_account uuid; v_class text; v_school text;
  v_structure record; v_installment uuid;
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  select s.class_name, s.school_code into v_class,v_school
  from public.student_roster s where s.id=p_student_id and s.status='ACTIVE';
  if not found or v_school <> 'ashiana' then raise exception 'Active Ashiana student not found'; end if;
  if not exists(select 1 from public.fee_academic_years y where y.id=p_academic_year_id and y.school_code='ashiana') then
    raise exception 'Academic year not found';
  end if;
  insert into public.student_fee_accounts(school_code,academic_year_id,student_id,created_by)
  values ('ashiana',p_academic_year_id,p_student_id,v_actor)
  on conflict (academic_year_id,student_id) do update set school_code='ashiana'
  returning id into v_account;

  for v_structure in
    select fs.id,fs.amount_paise,fs.due_date from public.fee_structures fs
    where fs.academic_year_id=p_academic_year_id and fs.school_code='ashiana'
      and fs.class_name=v_class
  loop
    if not exists(select 1 from public.fee_installments i where i.fee_account_id=v_account and i.fee_structure_id=v_structure.id) then
      insert into public.fee_installments(fee_account_id,fee_structure_id,installment_no,amount_paise,due_date)
      values (v_account,v_structure.id,1,v_structure.amount_paise,coalesce(v_structure.due_date,(select y.starts_on from public.fee_academic_years y where y.id=p_academic_year_id)))
      returning id into v_installment;
    end if;
  end loop;
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
  values ('ashiana',v_actor,'STUDENT_FEE_ACCOUNT_ASSIGNED','student_fee_account',v_account,
    jsonb_build_object('student_id',p_student_id,'academic_year_id',p_academic_year_id));
  return v_account;
end;
$$;

create or replace function public.fee_admin_assign_principal_approver(
  p_user_id uuid, p_enabled boolean default true
) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid();
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  if p_user_id is null then raise exception 'Principal user ID is required'; end if;
  if p_enabled then
    insert into public.fee_principal_approvers(user_id,school_code,is_enabled,assigned_by)
    values (p_user_id,'ashiana',true,v_actor)
    on conflict (user_id) do update set school_code='ashiana',is_enabled=true,assigned_by=v_actor,assigned_at=now();
  else
    update public.fee_principal_approvers set is_enabled=false,assigned_by=v_actor,assigned_at=now()
    where user_id=p_user_id and school_code='ashiana';
  end if;
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,details)
  values ('ashiana',v_actor,case when p_enabled then 'PRINCIPAL_APPROVER_ENABLED' else 'PRINCIPAL_APPROVER_DISABLED' end,
    'fee_principal_approver',jsonb_build_object('user_id',p_user_id));
end;
$$;

create or replace function public.fee_admin_create_discount_request(
  p_fee_account_id uuid, p_amount_paise bigint, p_reason text
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid(); v_id uuid;
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  if p_amount_paise is null or p_amount_paise <= 0 or length(trim(coalesce(p_reason,''))) not between 3 and 1000 then
    raise exception 'Discount amount and reason are required';
  end if;
  if not exists(select 1 from public.student_fee_accounts a where a.id=p_fee_account_id and a.school_code='ashiana') then
    raise exception 'Fee account not found';
  end if;
  insert into public.fee_discount_requests(fee_account_id,amount_paise,reason,requested_by)
  values (p_fee_account_id,p_amount_paise,trim(p_reason),v_actor)
  returning id into v_id;
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,entity_id,details)
  values ('ashiana',v_actor,'DISCOUNT_REQUESTED','fee_discount_request',v_id,
    jsonb_build_object('fee_account_id',p_fee_account_id,'amount_paise',p_amount_paise,'reason',trim(p_reason)));
  return v_id;
end;
$$;

revoke all on function public.fee_admin_save_academic_year(text,date,date,boolean) from public, anon;
revoke all on function public.fee_admin_save_structure(uuid,text,text,bigint,boolean,date) from public, anon;
revoke all on function public.fee_admin_assign_student_account(uuid,uuid) from public, anon;
revoke all on function public.fee_admin_assign_principal_approver(uuid,boolean) from public, anon;
revoke all on function public.fee_admin_create_discount_request(uuid,bigint,text) from public, anon;
grant execute on function public.fee_admin_save_academic_year(text,date,date,boolean) to authenticated;
grant execute on function public.fee_admin_save_structure(uuid,text,text,bigint,boolean,date) to authenticated;
grant execute on function public.fee_admin_assign_student_account(uuid,uuid) to authenticated;
grant execute on function public.fee_admin_assign_principal_approver(uuid,boolean) to authenticated;
grant execute on function public.fee_admin_create_discount_request(uuid,bigint,text) to authenticated;

commit;
