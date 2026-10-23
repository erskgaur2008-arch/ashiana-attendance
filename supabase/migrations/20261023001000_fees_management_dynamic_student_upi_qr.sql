-- Add verified UPI beneficiary details for amount-specific student payment QR codes.
begin;
alter table public.fee_school_payment_settings
  add column if not exists upi_id text,
  add column if not exists payee_name text;

alter table public.fee_school_payment_settings
  drop constraint if exists fee_school_payment_settings_upi_id_check;
alter table public.fee_school_payment_settings
  add constraint fee_school_payment_settings_upi_id_check
  check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$');
alter table public.fee_school_payment_settings
  drop constraint if exists fee_school_payment_settings_payee_name_check;
alter table public.fee_school_payment_settings
  add constraint fee_school_payment_settings_payee_name_check
  check (payee_name is null or length(trim(payee_name)) between 2 and 80);

drop function if exists public.fee_admin_save_school_upi_qr(text);
create function public.fee_admin_save_school_upi_qr(p_data_url text, p_upi_id text, p_payee_name text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid();
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  if p_data_url is null or length(p_data_url) < 100 or length(p_data_url) > 1400000 or
     p_data_url !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$' then
    raise exception 'Upload a valid PNG, JPEG, or WebP QR image under 1 MB';
  end if;
  if p_upi_id is null or p_upi_id !~ '^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$' then
    raise exception 'Provide a valid school UPI ID';
  end if;
  if p_payee_name is null or length(trim(p_payee_name)) < 2 or length(trim(p_payee_name)) > 80 then
    raise exception 'Provide the verified school payee name';
  end if;
  insert into public.fee_school_payment_settings(school_code,upi_qr_data_url,upi_id,payee_name,updated_by,updated_at)
  values ('ashiana',p_data_url,trim(p_upi_id),trim(p_payee_name),v_actor,now())
  on conflict (school_code) do update set upi_qr_data_url=excluded.upi_qr_data_url,
    upi_id=excluded.upi_id,payee_name=excluded.payee_name,
    updated_by=excluded.updated_by,updated_at=now();
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,details)
  values ('ashiana',v_actor,'SCHOOL_UPI_DETAILS_UPDATED','fee_school_payment_settings',
    jsonb_build_object('updated_at',now(),'upi_id',trim(p_upi_id),'payee_name',trim(p_payee_name),
      'image_bytes_approx',length(p_data_url)*3/4));
end;
$$;
revoke all on function public.fee_admin_save_school_upi_qr(text,text,text) from public, anon;
grant execute on function public.fee_admin_save_school_upi_qr(text,text,text) to authenticated;
commit;
