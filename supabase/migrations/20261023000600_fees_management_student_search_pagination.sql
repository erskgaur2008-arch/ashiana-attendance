-- Fees Management: paginated student search for safe class-wide account assignment.
create or replace function public.fee_admin_search_students_page(
  p_query text default '',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (student_id uuid, student_name text, enroll_no text, class_name text, section text)
language plpgsql security definer set search_path = ''
as $function$
declare
  v_query text := lower(trim(coalesce(p_query,'')));
  v_limit integer := greatest(1, least(coalesce(p_limit,50), 100));
  v_offset integer := greatest(0, coalesce(p_offset,0));
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'Admin permission required'; end if;
  return query
  select s.id, s.student_name::text, s.enroll_no::text, s.class_name::text, s.section::text
  from public.student_roster s
  where s.school_code='ashiana' and s.status='ACTIVE'
    and (v_query='' or lower(coalesce(s.student_name,'')) like '%'||v_query||'%'
      or lower(coalesce(s.enroll_no,'')) like '%'||v_query||'%'
      or lower(coalesce(s.class_name,'')) like '%'||v_query||'%')
  order by s.class_name, s.section, s.student_name, s.id
  limit v_limit offset v_offset;
end;
$function$;
revoke all on function public.fee_admin_search_students_page(text,integer,integer) from public, anon;
grant execute on function public.fee_admin_search_students_page(text,integer,integer) to authenticated;
