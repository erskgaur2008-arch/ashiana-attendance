-- Public login homepage content.
-- Exposes only active, published, school-wide notices/events intended for the public login screen.
create or replace function public.public_login_home_content(
  p_school_code text default 'ashiana'
)
returns jsonb
language sql
security definer
set search_path = public, private
as $$
  select jsonb_build_object(
    'notices',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'title', n.title,
          'body', left(regexp_replace(coalesce(n.body,''), '[[:space:]]+', ' ', 'g'), 220),
          'publish_at', n.publish_at
        )
        order by n.publish_at desc
      )
      from public.student_notices n
      where n.school_code = coalesce(nullif(trim(p_school_code), ''), 'ashiana')
        and n.active
        and n.publish_at <= now()
        and n.class_name is null
        and n.section is null
      limit 3
    ), '[]'::jsonb),
    'events',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'event_date', c.event_date,
          'title', c.title,
          'description', left(regexp_replace(coalesce(c.description,''), '[[:space:]]+', ' ', 'g'), 180)
        )
        order by c.event_date asc, c.created_at desc
      )
      from public.student_calendar_events c
      where c.school_code = coalesce(nullif(trim(p_school_code), ''), 'ashiana')
        and c.active
        and c.event_date >= current_date
        and c.class_name is null
        and c.section is null
      limit 3
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.public_login_home_content(text) from public;
grant execute on function public.public_login_home_content(text) to anon, authenticated;
