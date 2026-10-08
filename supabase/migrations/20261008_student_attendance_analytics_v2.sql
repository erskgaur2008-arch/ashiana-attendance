-- Advanced Attendance Analytics 2.0 - Phase 1
-- Read-only analytics RPC for the Admin portal. No attendance data is modified.

create or replace function public.admin_student_attendance_analytics(
  p_school_code text default 'ashiana',
  p_from_date date default ((now() at time zone 'Asia/Kolkata')::date),
  p_to_date date default ((now() at time zone 'Asia/Kolkata')::date),
  p_class_name text default null,
  p_section text default null,
  p_low_attendance_threshold numeric default 75
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_from date := least(coalesce(p_from_date, p_to_date), coalesce(p_to_date, p_from_date));
  v_to date := greatest(coalesce(p_from_date, p_to_date), coalesce(p_to_date, p_from_date));
  v_class text := nullif(trim(coalesce(p_class_name,'')), '');
  v_section text := nullif(trim(coalesce(p_section,'')), '');
  v_threshold numeric := greatest(0, least(100, coalesce(p_low_attendance_threshold,75)));
  v_result jsonb;
begin
  if not private.is_admin() then
    raise exception 'ADMIN_ACCESS_REQUIRED';
  end if;

  select jsonb_build_object(
    'filters', jsonb_build_object(
      'from_date', v_from,
      'to_date', v_to,
      'class_name', v_class,
      'section', v_section,
      'low_attendance_threshold', v_threshold
    ),
    'summary', (
      select jsonb_build_object(
        'active_students', count(*)::int,
        'marked_students', count(distinct a.student_id)::int,
        'marked_records', count(a.id)::int,
        'present', count(*) filter (where a.status='PRESENT')::int,
        'absent', count(*) filter (where a.status='ABSENT')::int,
        'leave', count(*) filter (where a.status='LEAVE')::int,
        'attendance_pct',
          coalesce(round(
            100.0 * count(*) filter (where a.status='PRESENT')
            / nullif(count(a.id),0), 1
          ), 0)
      )
      from public.student_roster s
      left join public.student_attendance a
        on a.school_code=s.school_code
       and a.student_id=s.id
       and a.attendance_date between v_from and v_to
      where s.school_code=p_school_code
        and s.status='ACTIVE'
        and (v_class is null or lower(trim(s.class_name))=lower(v_class))
        and (v_section is null or lower(trim(s.section))=lower(v_section))
    ),
    'class_rows', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.class_name, x.section)
      from (
        select
          s.class_name,
          s.section,
          count(distinct s.id)::int as total_students,
          count(distinct a.student_id)::int as marked_students,
          count(a.id) filter (where a.status='PRESENT')::int as present,
          count(a.id) filter (where a.status='ABSENT')::int as absent,
          count(a.id) filter (where a.status='LEAVE')::int as leave,
          coalesce(round(
            100.0 * count(a.id) filter (where a.status='PRESENT')
            / nullif(count(a.id),0), 1
          ),0) as attendance_pct
        from public.student_roster s
        left join public.student_attendance a
          on a.school_code=s.school_code
         and a.student_id=s.id
         and a.attendance_date between v_from and v_to
        where s.school_code=p_school_code
          and s.status='ACTIVE'
          and (v_class is null or lower(trim(s.class_name))=lower(v_class))
          and (v_section is null or lower(trim(s.section))=lower(v_section))
        group by s.class_name, s.section
      ) x
    ), '[]'::jsonb),
    'daily_rows', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.attendance_date)
      from (
        select
          a.attendance_date,
          count(a.id)::int as marked,
          count(a.id) filter (where a.status='PRESENT')::int as present,
          count(a.id) filter (where a.status='ABSENT')::int as absent,
          count(a.id) filter (where a.status='LEAVE')::int as leave,
          coalesce(round(
            100.0 * count(a.id) filter (where a.status='PRESENT')
            / nullif(count(a.id),0), 1
          ),0) as attendance_pct
        from public.student_attendance a
        join public.student_roster s on s.id=a.student_id and s.school_code=a.school_code
        where a.school_code=p_school_code
          and a.attendance_date between v_from and v_to
          and s.status='ACTIVE'
          and (v_class is null or lower(trim(s.class_name))=lower(v_class))
          and (v_section is null or lower(trim(s.section))=lower(v_section))
        group by a.attendance_date
      ) x
    ), '[]'::jsonb),
    'low_attendance', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.attendance_pct, x.class_name, x.section, x.student_name)
      from (
        select
          s.id,
          s.enroll_no,
          s.roll_no,
          s.student_name,
          s.class_name,
          s.section,
          count(a.id)::int as marked,
          count(a.id) filter (where a.status='PRESENT')::int as present,
          count(a.id) filter (where a.status='ABSENT')::int as absent,
          count(a.id) filter (where a.status='LEAVE')::int as leave,
          round(
            100.0 * count(a.id) filter (where a.status='PRESENT')
            / nullif(count(a.id),0), 1
          ) as attendance_pct
        from public.student_roster s
        join public.student_attendance a
          on a.school_code=s.school_code
         and a.student_id=s.id
         and a.attendance_date between v_from and v_to
        where s.school_code=p_school_code
          and s.status='ACTIVE'
          and (v_class is null or lower(trim(s.class_name))=lower(v_class))
          and (v_section is null or lower(trim(s.section))=lower(v_section))
        group by s.id, s.enroll_no, s.roll_no, s.student_name, s.class_name, s.section
        having round(
          100.0 * count(a.id) filter (where a.status='PRESENT')
          / nullif(count(a.id),0), 1
        ) < v_threshold
        order by attendance_pct, s.class_name, s.section, s.student_name
        limit 100
      ) x
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.admin_student_attendance_analytics(text,date,date,text,text,numeric) from public, anon;
grant execute on function public.admin_student_attendance_analytics(text,date,date,text,text,numeric) to authenticated;

-- Phase 2: student-level trend/action data for Admin analytics.
create or replace function public.admin_student_attendance_analytics_v2(
  p_school_code text default 'ashiana',
  p_from_date date default ((now() at time zone 'Asia/Kolkata')::date),
  p_to_date date default ((now() at time zone 'Asia/Kolkata')::date),
  p_class_name text default null,
  p_section text default null,
  p_low_attendance_threshold numeric default 75
)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_from date := least(coalesce(p_from_date, p_to_date), coalesce(p_to_date, p_from_date));
  v_to date := greatest(coalesce(p_from_date, p_to_date), coalesce(p_to_date, p_from_date));
  v_class text := nullif(trim(coalesce(p_class_name,'')), '');
  v_section text := nullif(trim(coalesce(p_section,'')), '');
  v_threshold numeric := greatest(0, least(100, coalesce(p_low_attendance_threshold,75)));
  v_result jsonb;
begin
  if not private.is_admin() then raise exception 'ADMIN_ACCESS_REQUIRED'; end if;

  select jsonb_build_object(
    'student_rows', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.attendance_pct, x.class_name, x.section, x.student_name)
      from (
        select s.id,s.enroll_no,s.roll_no,s.student_name,s.class_name,s.section,
          count(a.id)::int as marked,
          count(a.id) filter(where a.status='PRESENT')::int as present,
          count(a.id) filter(where a.status='ABSENT')::int as absent,
          count(a.id) filter(where a.status='LEAVE')::int as leave,
          round(100.0*count(a.id) filter(where a.status='PRESENT')/nullif(count(a.id),0),1) as attendance_pct
        from public.student_roster s
        join public.student_attendance a on a.school_code=s.school_code and a.student_id=s.id
          and a.attendance_date between v_from and v_to
        where s.school_code=p_school_code and s.status='ACTIVE'
          and (v_class is null or lower(trim(s.class_name))=lower(v_class))
          and (v_section is null or lower(trim(s.section))=lower(v_section))
        group by s.id,s.enroll_no,s.roll_no,s.student_name,s.class_name,s.section
      ) x limit 500
    ), '[]'::jsonb),
    'chronic_absence', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.absent_days desc, x.attendance_pct, x.student_name)
      from (
        select s.id,s.enroll_no,s.roll_no,s.student_name,s.class_name,s.section,
          count(a.id) filter(where a.status='ABSENT')::int as absent_days,
          count(a.id)::int as marked,
          round(100.0*count(a.id) filter(where a.status='PRESENT')/nullif(count(a.id),0),1) as attendance_pct
        from public.student_roster s
        join public.student_attendance a on a.school_code=s.school_code and a.student_id=s.id
          and a.attendance_date between v_from and v_to
        where s.school_code=p_school_code and s.status='ACTIVE'
          and (v_class is null or lower(trim(s.class_name))=lower(v_class))
          and (v_section is null or lower(trim(s.section))=lower(v_section))
        group by s.id,s.enroll_no,s.roll_no,s.student_name,s.class_name,s.section
        having count(a.id) filter(where a.status='ABSENT') >= 3
        order by absent_days desc, attendance_pct, student_name
        limit 100
      ) x
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_student_attendance_analytics_v2(text,date,date,text,text,numeric) from public, anon;
grant execute on function public.admin_student_attendance_analytics_v2(text,date,date,text,text,numeric) to authenticated;
