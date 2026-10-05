-- Final RLS auth helper performance hardening.
-- Converts remaining direct auth.jwt()/auth.uid() calls in policy expressions
-- to statement-scoped SELECT wrappers without changing authorization semantics.
do $$
declare r record; q text; w text;
begin
  for r in
    select p.polname, c.relname, n.nspname,
           pg_get_expr(p.polqual,p.polrelid) qual,
           pg_get_expr(p.polwithcheck,p.polrelid) with_check
    from pg_policy p
    join pg_class c on c.oid=p.polrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
  loop
    q:=r.qual; w:=r.with_check;
    if q is not null and q like '%auth.jwt()%' and q not like '%( SELECT (auth.jwt()%' then
      q:=replace(q,'auth.jwt()','(select auth.jwt())');
    end if;
    if q is not null and q like '%auth.uid()%' and q not like '%( SELECT (auth.uid()%' then
      q:=replace(q,'auth.uid()','(select auth.uid())');
    end if;
    if w is not null and w like '%auth.jwt()%' and w not like '%( SELECT (auth.jwt()%' then
      w:=replace(w,'auth.jwt()','(select auth.jwt())');
    end if;
    if w is not null and w like '%auth.uid()%' and w not like '%( SELECT (auth.uid()%' then
      w:=replace(w,'auth.uid()','(select auth.uid())');
    end if;
    if q is distinct from r.qual or w is distinct from r.with_check then
      execute format('alter policy %I on %I.%I%s%s',r.polname,r.nspname,r.relname,
        case when q is not null and q is distinct from r.qual then ' using ('||q||')' else '' end,
        case when w is not null and w is distinct from r.with_check then ' with check ('||w||')' else '' end);
    end if;
  end loop;
end $$;
