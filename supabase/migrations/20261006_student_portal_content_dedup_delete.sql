-- Prevent duplicate active student portal Notices/Homework and allow teachers to delete their own content.
-- Existing exact duplicates are consolidated before the unique indexes are created.

with ranked as (
  select id, row_number() over (
    partition by school_code, coalesce(class_name,''), coalesce(section,''),
                 lower(trim(title)), md5(coalesce(body,'')), lower(coalesce(published_by,''))
    order by created_at asc, id asc
  ) rn
  from public.student_notices where active
)
delete from public.student_notices n using ranked r where n.id=r.id and r.rn>1;

with ranked as (
  select id, row_number() over (
    partition by school_code, coalesce(class_name,''), coalesce(section,''),
                 lower(trim(title)), md5(coalesce(description,'')),
                 lower(trim(coalesce(subject_name,''))), due_date
    order by created_at asc, id asc
  ) rn
  from public.student_homework where active
)
delete from public.student_homework h using ranked r where h.id=r.id and r.rn>1;

create unique index if not exists student_notices_active_unique_idx
  on public.student_notices (school_code, coalesce(class_name,''), coalesce(section,''), lower(trim(title)), md5(coalesce(body,'')), lower(coalesce(published_by,'')))
  where active;

create unique index if not exists student_homework_active_unique_idx
  on public.student_homework (school_code, coalesce(class_name,''), coalesce(section,''), lower(trim(title)), md5(coalesce(description,'')), lower(trim(coalesce(subject_name,''))), due_date)
  where active;

drop policy if exists student_notices_manage on public.student_notices;
create policy student_notices_insert on public.student_notices for insert to authenticated
with check (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_notices.class_name and a.section=student_notices.section
    )
  )
);
create policy student_notices_update on public.student_notices for update to authenticated
using (
  school_code='ashiana' and (
    (select private.is_admin()) or (
      lower(coalesce(published_by,''))=lower(coalesce((select auth.jwt()->>'email'),''))
      and exists (
        select 1 from public.student_class_assignments a
        where a.school_code='ashiana' and a.active
          and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
          and a.class_name=student_notices.class_name and a.section=student_notices.section
      )
    )
  )
) with check (school_code='ashiana');
create policy student_notices_delete on public.student_notices for delete to authenticated
using (school_code='ashiana' and ((select private.is_admin()) or lower(coalesce(published_by,''))=lower(coalesce((select auth.jwt()->>'email'),''))));

drop policy if exists student_homework_manage on public.student_homework;
create policy student_homework_insert on public.student_homework for insert to authenticated
with check (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_homework.class_name and a.section=student_homework.section
    )
  )
);
create policy student_homework_update on public.student_homework for update to authenticated
using (
  school_code='ashiana' and (
    (select private.is_admin()) or (
      lower(coalesce(published_by,''))=lower(coalesce((select auth.jwt()->>'email'),''))
      and exists (
        select 1 from public.student_class_assignments a
        where a.school_code='ashiana' and a.active
          and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
          and a.class_name=student_homework.class_name and a.section=student_homework.section
      )
    )
  )
) with check (school_code='ashiana');
create policy student_homework_delete on public.student_homework for delete to authenticated
using (school_code='ashiana' and ((select private.is_admin()) or lower(coalesce(published_by,''))=lower(coalesce((select auth.jwt()->>'email'),''))));
