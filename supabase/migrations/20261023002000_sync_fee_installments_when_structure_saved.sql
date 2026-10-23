-- Keep student fee accounts in sync when an admin creates or updates a fee structure.
-- Existing payment history is not modified. Existing installments are left unchanged.
create or replace function public.fee_admin_save_structure(
  p_academic_year_id uuid,
  p_class_name text,
  p_fee_name text,
  p_amount_paise bigint,
  p_is_mandatory boolean,
  p_due_date date
)
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  if v_actor is null or not private.is_admin() then
    raise exception 'Admin permission required';
  end if;

  if p_amount_paise is null or p_amount_paise < 0
     or length(trim(coalesce(p_class_name, ''))) = 0
     or length(trim(coalesce(p_fee_name, ''))) not between 2 and 100 then
    raise exception 'Fee structure values are invalid';
  end if;

  if not exists (
    select 1 from public.fee_academic_years y
    where y.id = p_academic_year_id and y.school_code = 'ashiana'
  ) then
    raise exception 'Academic year not found';
  end if;

  insert into public.fee_structures(
    school_code, academic_year_id, class_name, fee_name,
    amount_paise, is_mandatory, due_date, created_by
  )
  values (
    'ashiana', p_academic_year_id, trim(p_class_name), trim(p_fee_name),
    p_amount_paise, p_is_mandatory, p_due_date, v_actor
  )
  on conflict (academic_year_id, class_name, fee_name) do update set
    amount_paise = excluded.amount_paise,
    is_mandatory = excluded.is_mandatory,
    due_date = excluded.due_date
  returning id into v_id;

  -- Create missing installments for already-assigned student fee accounts in
  -- the matching class/section. Never overwrite existing installments because
  -- they may have payment history or prior adjustments.
  insert into public.fee_installments(
    fee_account_id, fee_structure_id, installment_no, amount_paise, due_date
  )
  select
    sfa.id,
    v_id,
    1,
    p_amount_paise,
    coalesce(p_due_date, y.starts_on)
  from public.student_fee_accounts sfa
  join public.student_roster s
    on s.id = sfa.student_id
   and s.status = 'ACTIVE'
   and s.school_code = 'ashiana'
  join public.fee_academic_years y
    on y.id = sfa.academic_year_id
   and y.school_code = 'ashiana'
  where sfa.school_code = 'ashiana'
    and sfa.academic_year_id = p_academic_year_id
    and (
      trim(coalesce(s.class_name, '')) = trim(p_class_name)
      or trim(coalesce(s.class_name, '')) || '-' || trim(coalesce(s.section, '')) = trim(p_class_name)
    )
  on conflict (fee_account_id, fee_structure_id, installment_no) do nothing;

  insert into public.fee_audit_log(
    school_code, actor_id, action, entity_type, entity_id, details
  )
  values (
    'ashiana', v_actor, 'FEE_STRUCTURE_SAVED', 'fee_structure', v_id,
    jsonb_build_object(
      'academic_year_id', p_academic_year_id,
      'class_name', trim(p_class_name),
      'fee_name', trim(p_fee_name),
      'amount_paise', p_amount_paise
    )
  );

  return v_id;
end;
$$;
