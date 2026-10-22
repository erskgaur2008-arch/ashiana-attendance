-- Private storage bucket for payment evidence. The bucket is private and intentionally
-- has no direct anon/authenticated object policies. Upload/download must be mediated
-- by an authorized Edge Function that validates the student session or staff role.
begin;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fee-payment-proofs','fee-payment-proofs',false,5242880,
  array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update set
  public=false,
  file_size_limit=5242880,
  allowed_mime_types=excluded.allowed_mime_types;
commit;
