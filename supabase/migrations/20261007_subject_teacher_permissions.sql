-- Subject Teacher permissions aligned with the approved Ashiana Attendance role matrix.
-- Class Teachers retain their existing class/section access.
-- Subject Teachers gain access through active subject assignments.
-- Leave management remains Class Teacher-only.

drop policy if exists student_notices_select on public.student_notices;
create policy student_notices_select on public.student_notices
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_notices.class_name and a.section=student_notices.section
    ) or exists (
      select 1 from public.student_subject_assignments sa
      where sa.school_code='ashiana' and sa.active
        and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and sa.class_name=student_notices.class_name and sa.section=student_notices.section
    )
  )
);

drop policy if exists student_notices_insert on public.student_notices;
create policy student_notices_insert on public.student_notices
for insert to authenticated with check (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_notices.class_name and a.section=student_notices.section
    ) or exists (
      select 1 from public.student_subject_assignments sa
      where sa.school_code='ashiana' and sa.active
        and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and sa.class_name=student_notices.class_name and sa.section=student_notices.section
    )
  )
);

drop policy if exists student_notices_update on public.student_notices;
create policy student_notices_update on public.student_notices
for update to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or (
      lower(coalesce(published_by,''))=lower(coalesce((select auth.jwt()->>'email'),''))
      and (
        exists (
          select 1 from public.student_class_assignments a
          where a.school_code='ashiana' and a.active
            and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and a.class_name=student_notices.class_name and a.section=student_notices.section
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code='ashiana' and sa.active
            and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and sa.class_name=student_notices.class_name and sa.section=student_notices.section
        )
      )
    )
  )
) with check (school_code='ashiana');

drop policy if exists student_homework_select on public.student_homework;
create policy student_homework_select on public.student_homework
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_homework.class_name and a.section=student_homework.section
    ) or exists (
      select 1 from public.student_subject_assignments sa
      where sa.school_code='ashiana' and sa.active
        and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and sa.class_name=student_homework.class_name and sa.section=student_homework.section
    )
  )
);

drop policy if exists student_homework_insert on public.student_homework;
create policy student_homework_insert on public.student_homework
for insert to authenticated with check (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_homework.class_name and a.section=student_homework.section
    ) or exists (
      select 1 from public.student_subject_assignments sa
      where sa.school_code='ashiana' and sa.active
        and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and sa.class_name=student_homework.class_name and sa.section=student_homework.section
        and lower(trim(sa.subject_name))=lower(trim(student_homework.subject_name))
    )
  )
);

drop policy if exists student_homework_update on public.student_homework;
create policy student_homework_update on public.student_homework
for update to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or (
      lower(coalesce(published_by,''))=lower(coalesce((select auth.jwt()->>'email'),''))
      and (
        exists (
          select 1 from public.student_class_assignments a
          where a.school_code='ashiana' and a.active
            and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and a.class_name=student_homework.class_name and a.section=student_homework.section
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code='ashiana' and sa.active
            and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and sa.class_name=student_homework.class_name and sa.section=student_homework.section
            and lower(trim(sa.subject_name))=lower(trim(student_homework.subject_name))
        )
      )
    )
  )
) with check (
  school_code='ashiana' and (
    (select private.is_admin()) or (
      lower(coalesce(published_by,''))=lower(coalesce((select auth.jwt()->>'email'),''))
      and (
        exists (
          select 1 from public.student_class_assignments a
          where a.school_code='ashiana' and a.active
            and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and a.class_name=student_homework.class_name and a.section=student_homework.section
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code='ashiana' and sa.active
            and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and sa.class_name=student_homework.class_name and sa.section=student_homework.section
            and lower(trim(sa.subject_name))=lower(trim(student_homework.subject_name))
        )
      )
    )
  )
);

drop policy if exists student_roster_teacher_select on public.student_roster;
create policy student_roster_teacher_select on public.student_roster
for select to authenticated using (
  exists (
    select 1 from public.student_class_assignments a
    where a.school_code=student_roster.school_code
      and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
      and a.class_name=student_roster.class_name and a.section=student_roster.section and a.active
  ) or exists (
    select 1 from public.student_subject_assignments sa
    where sa.school_code=student_roster.school_code
      and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
      and sa.class_name=student_roster.class_name and sa.section=student_roster.section and sa.active
  )
);

drop policy if exists student_attendance_teacher_select on public.student_attendance;
create policy student_attendance_teacher_select on public.student_attendance
for select to authenticated using (
  exists (
    select 1 from public.student_roster s
    where s.id=student_attendance.student_id and s.school_code=student_attendance.school_code
      and (
        exists (
          select 1 from public.student_class_assignments a
          where a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section
            and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and a.active
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code=s.school_code and sa.class_name=s.class_name and sa.section=s.section
            and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and sa.active
        )
      )
  )
);

drop policy if exists student_attendance_teacher_insert on public.student_attendance;
create policy student_attendance_teacher_insert on public.student_attendance
for insert to authenticated with check (
  (select auth.uid())=marked_by and exists (
    select 1 from public.student_roster s
    where s.id=student_attendance.student_id and s.school_code=student_attendance.school_code
      and (
        exists (
          select 1 from public.student_class_assignments a
          where a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section
            and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and a.active
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code=s.school_code and sa.class_name=s.class_name and sa.section=s.section
            and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and sa.active
        )
      )
  )
);

drop policy if exists student_attendance_teacher_update on public.student_attendance;
create policy student_attendance_teacher_update on public.student_attendance
for update to authenticated using (
  exists (
    select 1 from public.student_roster s
    where s.id=student_attendance.student_id and s.school_code=student_attendance.school_code
      and (
        exists (
          select 1 from public.student_class_assignments a
          where a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section
            and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and a.active
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code=s.school_code and sa.class_name=s.class_name and sa.section=s.section
            and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and sa.active
        )
      )
  )
) with check (
  (select auth.uid())=marked_by and exists (
    select 1 from public.student_roster s
    where s.id=student_attendance.student_id and s.school_code=student_attendance.school_code
      and (
        exists (
          select 1 from public.student_class_assignments a
          where a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section
            and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and a.active
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code=s.school_code and sa.class_name=s.class_name and sa.section=s.section
            and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
            and sa.active
        )
      )
  )
);

drop policy if exists student_timetable_select on public.student_timetable;
create policy student_timetable_select on public.student_timetable
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin()) or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and a.active
        and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and a.class_name=student_timetable.class_name and a.section=student_timetable.section
    ) or exists (
      select 1 from public.student_subject_assignments sa
      where sa.school_code='ashiana' and sa.active
        and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
        and sa.class_name=student_timetable.class_name and sa.section=student_timetable.section
    )
  )
);

drop policy if exists student_timetable_manage on public.student_timetable;
create policy student_timetable_manage on public.student_timetable
for all to authenticated using (
  school_code='ashiana' and (
    private.is_admin() or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and lower(a.teacher_email)=lower((select auth.jwt()->>'email'))
        and a.active and a.class_name=student_timetable.class_name and a.section=student_timetable.section
    ) or exists (
      select 1 from public.student_subject_assignments sa
      where sa.school_code='ashiana' and lower(sa.teacher_email)=lower((select auth.jwt()->>'email'))
        and sa.active and sa.class_name=student_timetable.class_name and sa.section=student_timetable.section
        and lower(trim(sa.subject_name))=lower(trim(student_timetable.subject_name))
    )
  )
) with check (
  school_code='ashiana' and (
    private.is_admin() or (
      lower(coalesce(created_by,''))=lower((select auth.jwt()->>'email')) and (
        exists (
          select 1 from public.student_class_assignments a
          where a.school_code='ashiana' and lower(a.teacher_email)=lower((select auth.jwt()->>'email'))
            and a.active and a.class_name=student_timetable.class_name and a.section=student_timetable.section
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code='ashiana' and lower(sa.teacher_email)=lower((select auth.jwt()->>'email'))
            and sa.active and sa.class_name=student_timetable.class_name and sa.section=student_timetable.section
            and lower(trim(sa.subject_name))=lower(trim(student_timetable.subject_name))
        )
      )
    )
  )
);

drop policy if exists student_calendar_select on public.student_calendar_events;
create policy student_calendar_select on public.student_calendar_events
for select to authenticated using (
  school_code='ashiana' and (
    private.is_admin() or class_name is null or exists (
      select 1 from public.student_class_assignments a
      where a.school_code='ashiana' and lower(a.teacher_email)=lower((select auth.jwt()->>'email'))
        and a.active and a.class_name=student_calendar_events.class_name and a.section=student_calendar_events.section
    ) or exists (
      select 1 from public.student_subject_assignments sa
      where sa.school_code='ashiana' and lower(sa.teacher_email)=lower((select auth.jwt()->>'email'))
        and sa.active and sa.class_name=student_calendar_events.class_name and sa.section=student_calendar_events.section
    )
  )
);

drop policy if exists student_calendar_manage on public.student_calendar_events;
create policy student_calendar_manage on public.student_calendar_events
for all to authenticated using (
  school_code='ashiana' and (
    private.is_admin() or (
      lower(coalesce(created_by,''))=lower((select auth.jwt()->>'email')) and (
        class_name is null or exists (
          select 1 from public.student_class_assignments a
          where a.school_code='ashiana' and lower(a.teacher_email)=lower((select auth.jwt()->>'email'))
            and a.active and a.class_name=student_calendar_events.class_name and a.section=student_calendar_events.section
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code='ashiana' and lower(sa.teacher_email)=lower((select auth.jwt()->>'email'))
            and sa.active and sa.class_name=student_calendar_events.class_name and sa.section=student_calendar_events.section
        )
      )
    )
  )
) with check (
  school_code='ashiana' and (
    private.is_admin() or (
      lower(coalesce(created_by,''))=lower((select auth.jwt()->>'email')) and (
        class_name is null or exists (
          select 1 from public.student_class_assignments a
          where a.school_code='ashiana' and lower(a.teacher_email)=lower((select auth.jwt()->>'email'))
            and a.active and a.class_name=student_calendar_events.class_name and a.section=student_calendar_events.section
        ) or exists (
          select 1 from public.student_subject_assignments sa
          where sa.school_code='ashiana' and lower(sa.teacher_email)=lower((select auth.jwt()->>'email'))
            and sa.active and sa.class_name=student_calendar_events.class_name and sa.section=student_calendar_events.section
        )
      )
    )
  )
);

drop policy if exists student_report_select on public.student_report_cards;
create policy student_report_select on public.student_report_cards
for select to authenticated using (
  school_code='ashiana' and (
    (select private.is_admin())
    or lower(published_by)=lower(coalesce((select auth.jwt()->>'email'),''))
    or exists (
      select 1
      from public.student_roster s
      where s.id=student_report_cards.student_id
        and (
          exists (
            select 1 from public.student_class_assignments a
            where a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section
              and lower(a.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
              and a.active
          ) or exists (
            select 1 from public.student_subject_assignments sa
            where sa.school_code=s.school_code and sa.class_name=s.class_name and sa.section=s.section
              and lower(sa.teacher_email)=lower(coalesce((select auth.jwt()->>'email'),''))
              and sa.active
          )
        )
    )
  )
);

drop policy if exists student_report_manage on public.student_report_cards;
create policy student_report_manage on public.student_report_cards
for all to authenticated using (
  school_code='ashiana' and (
    private.is_admin() or (
      lower(coalesce(published_by,''))=lower((select auth.jwt()->>'email')) and exists (
        select 1 from public.student_roster s
        where s.id=student_report_cards.student_id
          and (
            exists (
              select 1 from public.student_class_assignments a
              where a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section
                and lower(a.teacher_email)=lower((select auth.jwt()->>'email')) and a.active
            ) or exists (
              select 1 from public.student_subject_assignments sa
              where sa.school_code=s.school_code and sa.class_name=s.class_name and sa.section=s.section
                and lower(sa.teacher_email)=lower((select auth.jwt()->>'email')) and sa.active
            )
          )
      )
    )
  )
) with check (
  school_code='ashiana' and (
    private.is_admin() or (
      lower(coalesce(published_by,''))=lower((select auth.jwt()->>'email')) and exists (
        select 1 from public.student_roster s
        where s.id=student_report_cards.student_id
          and (
            exists (
              select 1 from public.student_class_assignments a
              where a.school_code=s.school_code and a.class_name=s.class_name and a.section=s.section
                and lower(a.teacher_email)=lower((select auth.jwt()->>'email')) and a.active
            ) or exists (
              select 1 from public.student_subject_assignments sa
              where sa.school_code=s.school_code and sa.class_name=s.class_name and sa.section=s.section
                and lower(sa.teacher_email)=lower((select auth.jwt()->>'email')) and sa.active
            )
          )
      )
    )
  )
);

-- Attendance QR RPC: allow both Class Teachers and Subject Teachers.
create or replace function public.mark_student_attendance_by_qr(p_school_code text, p_enroll_no text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email','')));
  v_teacher_name text := '';
  v_enroll text := upper(trim(coalesce(p_enroll_no,'')));
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_student public.student_roster%rowtype;
  v_mark public.student_attendance%rowtype;
  v_exists boolean := false;
begin
  if v_user_id is null or v_email = '' then
    return jsonb_build_object('success',false,'code','AUTH_REQUIRED','message','Teacher authentication is required.');
  end if;
  if lower(trim(coalesce(p_school_code,''))) <> 'ashiana' then
    return jsonb_build_object('success',false,'code','INVALID_SCHOOL','message','Invalid school.');
  end if;
  if v_enroll = '' then
    return jsonb_build_object('success',false,'code','INVALID_QR','message','Student enrollment number is missing.');
  end if;

  select coalesce(name,email) into v_teacher_name
  from public.staff
  where lower(trim(email))=v_email and status='ACTIVE'
  limit 1;
  v_teacher_name := coalesce(nullif(trim(v_teacher_name),''),v_email);

  select * into v_student
  from public.student_roster s
  where s.school_code='ashiana'
    and upper(trim(s.enroll_no))=v_enroll
    and s.status='ACTIVE'
  limit 1;

  if not found then
    return jsonb_build_object('success',false,'code','STUDENT_NOT_FOUND','message','Active student was not found for this QR code.');
  end if;

  if not exists (
    select 1 from public.student_class_assignments a
    where a.school_code='ashiana'
      and lower(trim(a.teacher_email))=v_email
      and a.class_name=v_student.class_name
      and a.section=v_student.section
      and a.active=true
  ) and not exists (
    select 1 from public.student_subject_assignments sa
    where sa.school_code='ashiana'
      and lower(trim(sa.teacher_email))=v_email
      and sa.class_name=v_student.class_name
      and sa.section=v_student.section
      and sa.active=true
  ) then
    return jsonb_build_object('success',false,'code','NOT_ASSIGNED','message','This student is not assigned to your class.','student',
      jsonb_build_object('enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section));
  end if;

  select exists(select 1 from public.student_attendance where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today) into v_exists;

  if v_exists then
    select * into v_mark from public.student_attendance
    where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today limit 1;
    return jsonb_build_object('success',true,'code','ALREADY_MARKED','message','Attendance is already marked for this student today.','status',v_mark.status,'marked_at',v_mark.updated_at,'marked_by_name',coalesce(v_mark.marked_by_name,v_teacher_name),
      'student',jsonb_build_object('id',v_student.id,'enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section,'roll_no',v_student.roll_no));
  end if;

  insert into public.student_attendance(school_code,student_id,attendance_date,status,marked_by,marked_by_name,updated_at)
  values('ashiana',v_student.id,v_today,'PRESENT',v_user_id,v_teacher_name,now())
  returning * into v_mark;

  return jsonb_build_object('success',true,'code','MARKED','message','Student attendance marked present.','status',v_mark.status,'marked_at',v_mark.updated_at,'marked_by_name',v_teacher_name,
    'student',jsonb_build_object('id',v_student.id,'enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section,'roll_no',v_student.roll_no));
exception when unique_violation then
  select * into v_mark from public.student_attendance
  where school_code='ashiana' and student_id=v_student.id and attendance_date=v_today limit 1;
  return jsonb_build_object('success',true,'code','ALREADY_MARKED','message','Attendance was already marked by another scan.','status',coalesce(v_mark.status,'PRESENT'),'marked_at',v_mark.updated_at,'marked_by_name',coalesce(v_mark.marked_by_name,v_teacher_name),
    'student',jsonb_build_object('id',v_student.id,'enroll_no',v_student.enroll_no,'student_name',v_student.student_name,'class_name',v_student.class_name,'section',v_student.section,'roll_no',v_student.roll_no));
end;
$function$;
