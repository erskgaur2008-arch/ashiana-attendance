-- Isolated regression tests for class-teacher student mutation authorization.
-- Runs only against a synthetic PostgreSQL service in GitHub Actions.

create schema if not exists auth;
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create or replace function auth.uid() returns uuid
language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create or replace function auth.jwt() returns jsonb
language sql stable
as $$ select jsonb_build_object('email', current_setting('request.jwt.claim.email', true)) $$;

create or replace function public.public_login_home_content(p_school_code text default 'ashiana')
returns jsonb language sql security definer
set search_path to 'public', 'private'
as $ select jsonb_build_object('school_code', coalesce(p_school_code,'ashiana')) $;

\i supabase/migrations/20261026120000_harden_public_login_content_search_path.sql

do $
begin
  if (select proconfig from pg_proc where oid='public.public_login_home_content(text)'::regprocedure)
       is distinct from array['search_path=""']::text[] then
    raise exception 'public_login_home_content must use an empty search_path';
  end if;
end $;

create table public.staff (
  email text,
  status text,
  role text
);
create table public.student_roster (
  id uuid primary key,
  school_code text,
  class_name text,
  section text,
  student_name text,
  roll_no text,
  father_name text,
  mother_name text,
  dob date,
  phone_number text,
  address text,
  mode_of_transport text,
  updated_at timestamptz
);
create table public.student_class_assignments (
  school_code text,
  teacher_email text,
  class_name text,
  section text,
  active boolean
);

insert into public.staff(email,status,role) values
 ('active.teacher@example.test','ACTIVE','Class Teacher'),
 ('inactive.teacher@example.test','INACTIVE','Class Teacher'),
 ('subject.teacher@example.test','ACTIVE','Subject Teacher');

insert into public.student_roster(id,school_code,class_name,section,student_name)
values
 ('10000000-0000-4000-8000-000000000001','ashiana','II','A','Student One'),
 ('10000000-0000-4000-8000-000000000002','ashiana','III','B','Student Two');

-- Deliberately give the subject teacher a matching assignment row: role checks
-- must still prevent a subject teacher from using class-teacher mutation RPCs.
insert into public.student_class_assignments(school_code,teacher_email,class_name,section,active) values
 ('ashiana','active.teacher@example.test','II','A',true),
 ('ashiana','inactive.teacher@example.test','II','A',true),
 ('ashiana','subject.teacher@example.test','II','A',true);

\i supabase/migrations/20261026090000_harden_class_teacher_student_mutations.sql

do $$
declare
  v jsonb;
begin
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claim.email','',true);
  v := public.teacher_update_student_profile(
    '10000000-0000-4000-8000-000000000001','Changed Name',null,null,null,null,null
  );
  if v->>'code' <> 'AUTH_REQUIRED' then
    raise exception 'Unauthenticated mutation should fail closed, got %', v;
  end if;

  perform set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',true);
  perform set_config('request.jwt.claim.email','active.teacher@example.test',true);
  v := public.teacher_update_student_profile(
    '10000000-0000-4000-8000-000000000001','Changed Name',null,null,null,null,null
  );
  if v->>'success' <> 'true' then
    raise exception 'Active assigned class teacher should be allowed, got %', v;
  end if;

  perform set_config('request.jwt.claim.email','inactive.teacher@example.test',true);
  v := public.teacher_delete_student('10000000-0000-4000-8000-000000000001');
  if v->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'Inactive staff must be rejected, got %', v;
  end if;

  perform set_config('request.jwt.claim.email','subject.teacher@example.test',true);
  v := public.teacher_update_student_profile(
    '10000000-0000-4000-8000-000000000001','Unauthorized Name',null,null,null,null,null
  );
  if v->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'Subject teacher must be rejected, got %', v;
  end if;

  perform set_config('request.jwt.claim.email','active.teacher@example.test',true);
  v := public.teacher_delete_student('10000000-0000-4000-8000-000000000002');
  if v->>'code' <> 'NOT_AUTHORIZED' then
    raise exception 'Teacher outside assigned class must be rejected, got %', v;
  end if;
end $$;

do $$
begin
  if has_function_privilege('anon','public.teacher_delete_student(uuid)','EXECUTE') then
    raise exception 'anon must not execute teacher_delete_student';
  end if;
  if has_function_privilege('anon','public.teacher_update_student_profile(uuid,text,text,text,date,text,text)','EXECUTE') then
    raise exception 'anon must not execute teacher_update_student_profile';
  end if;
  if not has_function_privilege('authenticated','public.teacher_delete_student(uuid)','EXECUTE') then
    raise exception 'authenticated must retain teacher_delete_student execution';
  end if;
end $$;

select 'teacher mutation authorization tests passed' as result;
