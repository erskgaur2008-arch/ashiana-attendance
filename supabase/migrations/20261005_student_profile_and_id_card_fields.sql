-- Student profile fields, secure student photo storage, and ID card generation tracking.
alter table public.student_roster
  add column if not exists dob date,
  add column if not exists mother_name text,
  add column if not exists father_name text,
  add column if not exists address text,
  add column if not exists phone_number text,
  add column if not exists photo_path text,
  add column if not exists id_card_generated_at timestamptz;

create index if not exists student_roster_idcard_class_idx
  on public.student_roster (school_code, class_name, section, status);

-- Private bucket for student photos. Access is restricted to administrators by storage RLS.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('student-photos', 'student-photos', false, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
set public=false,
    file_size_limit=2097152,
    allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists student_photos_admin_select on storage.objects;
create policy student_photos_admin_select on storage.objects
for select to authenticated
using (bucket_id='student-photos' and private.is_admin());

drop policy if exists student_photos_admin_insert on storage.objects;
create policy student_photos_admin_insert on storage.objects
for insert to authenticated
with check (bucket_id='student-photos' and private.is_admin());

drop policy if exists student_photos_admin_update on storage.objects;
create policy student_photos_admin_update on storage.objects
for update to authenticated
using (bucket_id='student-photos' and private.is_admin())
with check (bucket_id='student-photos' and private.is_admin());

drop policy if exists student_photos_admin_delete on storage.objects;
create policy student_photos_admin_delete on storage.objects
for delete to authenticated
using (bucket_id='student-photos' and private.is_admin());