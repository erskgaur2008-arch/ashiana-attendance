alter table public.staff
  add column if not exists qualification text;

comment on column public.staff.qualification is
  'Staff member''s academic and professional qualifications, maintained by the staff member or an administrator.';
