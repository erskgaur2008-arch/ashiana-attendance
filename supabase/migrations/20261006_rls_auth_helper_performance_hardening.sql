-- Performance hardening for RLS auth helper calls.
-- Keep the existing authorization rules unchanged while ensuring auth.jwt()/auth.uid()
-- are evaluated once per statement instead of once per row.
do $$
declare
  r record;
  q text;
  w text;
begin
  for r in
    select p.polname, c.relname, n.nspname,
           pg_get_expr(p.polqual, p.polrelid) as qual,
           pg_get_expr(p.polwithcheck, p.polrelid) as with_check
    from pg_policy p
    join pg_class c on c.oid=p.polrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and (
        coalesce(pg_get_expr(p.polqual,p.polrelid),'') ~ 'auth\\.(jwt|uid)\\(\\)'
        or coalesce(pg_get_expr(p.polwithcheck,p.polrelid),'') ~ 'auth\\.(jwt|uid)\\(\\)'
      )
  loop
    q := r.qual;
    w := r.with_check;
    if q is not null then
      q := regexp_replace(q, '(?<!select )auth\\.jwt\\(\\)', '(select auth.jwt())', 'g');
      q := regexp_replace(q, '(?<!select )auth\\.uid\\(\\)', '(select auth.uid())', 'g');
    end if;
    if w is not null then
      w := regexp_replace(w, '(?<!select )auth\\.jwt\\(\\)', '(select auth.jwt())', 'g');
      w := regexp_replace(w, '(?<!select )auth\\.uid\\(\\)', '(select auth.uid())', 'g');
    end if;
    execute format(
      'alter policy %I on %I.%I%s%s',
      r.polname, r.nspname, r.relname,
      case when q is not null then ' using ('||q||')' else '' end,
      case when w is not null then ' with check ('||w||')' else '' end
    );
  end loop;
end $$;
