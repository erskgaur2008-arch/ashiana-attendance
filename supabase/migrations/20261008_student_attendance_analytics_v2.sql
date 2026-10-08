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


-- Phase 3: weekday patterns and consecutive-absence risk signals.
create or replace function public.admin_student_attendance_analytics_v3(
  p_school_code text default 'ashiana',
  p_from_date date default ((now() at time zone 'Asia/Kolkata')::date),
  p_to_date date default ((now() at time zone 'Asia/Kolkata')::date),
  p_class_name text default null,
  p_section text default null
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
  v_result jsonb;
begin
  if not private.is_admin() then raise exception 'ADMIN_ACCESS_REQUIRED'; end if;

  select jsonb_build_object(
    'weekday_rows', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.weekday_no)
      from (
        select extract(isodow from a.attendance_date)::int as weekday_no,
          trim(to_char(a.attendance_date,'Day')) as weekday_name,
          count(a.id)::int as marked,
          count(a.id) filter(where a.status='PRESENT')::int as present,
          count(a.id) filter(where a.status='ABSENT')::int as absent,
          count(a.id) filter(where a.status='LEAVE')::int as leave,
          coalesce(round(100.0*count(a.id) filter(where a.status='PRESENT')/nullif(count(a.id),0),1),0) as attendance_pct
        from public.student_attendance a
        join public.student_roster s on s.id=a.student_id and s.school_code=a.school_code
        where a.school_code=p_school_code
          and a.attendance_date between v_from and v_to
          and s.status='ACTIVE'
          and (v_class is null or lower(trim(s.class_name))=lower(v_class))
          and (v_section is null or lower(trim(s.section))=lower(v_section))
        group by extract(isodow from a.attendance_date), trim(to_char(a.attendance_date,'Day'))
      ) x
    ), '[]'::jsonb),
    'absence_streaks', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.max_absent_streak desc, x.attendance_pct, x.class_name, x.student_name)
      from (
        with ordered as (
          select s.id,s.enroll_no,s.roll_no,s.student_name,s.class_name,s.section,
            a.attendance_date,a.status,
            row_number() over(partition by s.id order by a.attendance_date,a.id) as rn,
            row_number() over(partition by s.id,a.status order by a.attendance_date,a.id) as status_rn
          from public.student_roster s
          join public.student_attendance a on a.school_code=s.school_code and a.student_id=s.id
            and a.attendance_date between v_from and v_to
          where s.school_code=p_school_code and s.status='ACTIVE'
            and (v_class is null or lower(trim(s.class_name))=lower(v_class))
            and (v_section is null or lower(trim(s.section))=lower(v_section))
        ), absent_groups as (
          select *, rn-status_rn as grp
          from ordered
          where status='ABSENT'
        ), streaks as (
          select id,enroll_no,roll_no,student_name,class_name,section,count(*)::int as streak_len,
            min(attendance_date) as streak_start,max(attendance_date) as streak_end
          from absent_groups
          group by id,enroll_no,roll_no,student_name,class_name,section,grp
        ), totals as (
          select s.id,
            count(a.id)::int as marked,
            count(a.id) filter(where a.status='PRESENT')::int as present
          from public.student_roster s
          join public.student_attendance a on a.school_code=s.school_code and a.student_id=s.id
            and a.attendance_date between v_from and v_to
          where s.school_code=p_school_code and s.status='ACTIVE'
            and (v_class is null or lower(trim(s.class_name))=lower(v_class))
            and (v_section is null or lower(trim(s.section))=lower(v_section))
          group by s.id
        )
        select st.id,st.enroll_no,st.roll_no,st.student_name,st.class_name,st.section,
          max(st.streak_len)::int as max_absent_streak,
          max(st.streak_start) filter(where st.streak_len=(select max(z.streak_len) from streaks z where z.id=st.id)) as streak_start,
          max(st.streak_end) filter(where st.streak_len=(select max(z.streak_len) from streaks z where z.id=st.id)) as streak_end,
          t.marked,t.present,
          coalesce(round(100.0*t.present/nullif(t.marked,0),1),0) as attendance_pct
        from streaks st
        join totals t on t.id=st.id
        group by st.id,st.enroll_no,st.roll_no,st.student_name,st.class_name,st.section,t.marked,t.present
        having max(st.streak_len) >= 2
        limit 100
      ) x
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.admin_student_attendance_analytics_v3(text,date,date,text,text) from public, anon;
grant execute on function public.admin_student_attendance_analytics_v3(text,date,date,text,text) to authenticated;
