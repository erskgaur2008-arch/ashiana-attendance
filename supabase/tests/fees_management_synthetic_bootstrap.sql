-- Synthetic Supabase-compatible schema for isolated migration validation only.
-- Never points at a live project and contains no real student data.
create role anon nologin;
create role authenticated nologin;
create schema if not exists auth;
create schema if not exists private;
create schema if not exists storage;
create extension if not exists pgcrypto;

create or replace function auth.uid()
returns uuid language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create table if not exists public.admin_users (
  user_id uuid primary key,
  role text not null
);

create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce(current_setting('request.jwt.claim.fee_admin', true), 'false') = 'true' $$;

create table if not exists public.student_roster (
  id uuid primary key default gen_random_uuid(),
  school_code text not null default 'ashiana',
  student_name text not null,
  enroll_no text not null,
  class_name text not null,
  section text,
  status text not null default 'ACTIVE'
);

create or replace function public.student_session_student_id(p_token text)
returns uuid language sql stable security definer set search_path = ''
as $$
  select case when p_token = 'synthetic-student-session-token-000000000000'
    then '11111111-1111-4111-8111-111111111111'::uuid else null end
$$;

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
