-- Admin-only deletion of unused fee structures; FK references protect historical records.
begin;
create or replace function public.fee_admin_delete_structure(p_fee_structure_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_row record;
begin
  if v_actor is null or not private.is_admin() then
    raise exception 'Admin permission required';
  end if;

  select id, school_code, academic_year_id, class_name, fee_name, amount_paise
    into v_row
    from public.fee_structures
   where id = p_fee_structure_id
     and school_code = 'ashiana'
   for update;

  if not found then
    raise exception 'Fee structure not found';
  end if;

  begin
    delete from public.fee_structures
     where id = p_fee_structure_id
       and school_code = 'ashiana';
  exception when foreign_key_violation then
    raise exception 'This fee structure is linked to existing fee or payment records and cannot be deleted. Existing records have been preserved.';
  end;

  insert into public.fee_audit_log(school_code, actor_id, action, entity_type, entity_id, details)
  values ('ashiana', v_actor, 'FEE_STRUCTURE_DELETED', 'fee_structures', v_row.id,
    jsonb_build_object('academic_year_id', v_row.academic_year_id, 'class_name', v_row.class_name,
      'fee_name', v_row.fee_name, 'amount_paise', v_row.amount_paise));

  return v_row.id;
end;
$$;
revoke all on function public.fee_admin_delete_structure(uuid) from public, anon;
grant execute on function public.fee_admin_delete_structure(uuid) to authenticated;
commit;
