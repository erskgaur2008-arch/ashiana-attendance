-- School UPI QR configuration for Fees Management. Additive and independent of attendance/payment history.
begin;
create table if not exists public.fee_school_payment_settings (
  school_code text primary key default 'ashiana',
  upi_qr_data_url text not null,
  updated_by uuid not null,
  updated_at timestamptz not null default now(),
  check (length(upi_qr_data_url) <= 1400000),
  check (upi_qr_data_url like 'data:image/png;base64,%' or upi_qr_data_url like 'data:image/jpeg;base64,%' or upi_qr_data_url like 'data:image/webp;base64,%')
);
alter table public.fee_school_payment_settings enable row level security;
revoke all on public.fee_school_payment_settings from anon, authenticated;
create or replace function public.fee_admin_save_school_upi_qr(p_data_url text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := auth.uid();
begin
  if v_actor is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  if p_data_url is null or length(p_data_url) > 1400000 or
     p_data_url !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$' then
    raise exception 'Upload a valid PNG, JPEG, or WebP QR image under 1 MB';
  end if;
  insert into public.fee_school_payment_settings(school_code,upi_qr_data_url,updated_by,updated_at)
  values ('ashiana',p_data_url,v_actor,now())
  on conflict (school_code) do update set upi_qr_data_url=excluded.upi_qr_data_url,
    updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  insert into public.fee_audit_log(school_code,actor_id,action,entity_type,details)
  values ('ashiana',v_actor,'SCHOOL_UPI_QR_UPDATED','fee_school_payment_settings',
    jsonb_build_object('updated_at',now(),'image_bytes_approx',length(p_data_url)*3/4));
end;
$$;
revoke all on function public.fee_admin_save_school_upi_qr(text) from public, anon;
grant execute on function public.fee_admin_save_school_upi_qr(text) to authenticated;
commit;
