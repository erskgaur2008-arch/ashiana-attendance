-- Student Portal PDF attachments for teacher-published notices and homework.
-- PDFs are stored in a dedicated public bucket so the RPC-based student portal
-- can open attachments without requiring a Supabase Auth session.

alter table public.student_notices
  add column if not exists attachment_path text,
  add column if not exists attachment_name text;

alter table public.student_homework
  add column if not exists attachment_path text,
  add column if not exists attachment_name text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'student-portal-documents',
  'student-portal-documents',
  true,
  10485760,
  array['application/pdf']::text[]
)
on conflict (id) do update
set public = true,
    file_size_limit = 10485760,
    allowed_mime_types = array['application/pdf']::text[];

drop policy if exists student_portal_documents_insert on storage.objects;
create policy student_portal_documents_insert
on storage.objects
for insert to authenticated
with check (
  bucket_id = 'student-portal-documents'
  and lower(name) like 'ashiana/%'
  and lower(name) like '%.pdf'
  and lower(split_part(name, '/', 2)) = lower(coalesce(auth.jwt()->>'email',''))
);

drop policy if exists student_portal_documents_delete on storage.objects;
create policy student_portal_documents_delete
on storage.objects
for delete to authenticated
using (
  bucket_id = 'student-portal-documents'
  and lower(split_part(name, '/', 2)) = lower(coalesce(auth.jwt()->>'email',''))
);

notify pgrst, 'reload schema';
