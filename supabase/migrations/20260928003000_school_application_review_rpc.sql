-- Atomic school application review and tenant provisioning.
-- Invoked only by the trusted approval Edge Function using service_role.
begin;

create or replace function public.review_school_application(
  p_application_id uuid,
  p_decision text,
  p_reviewer_id uuid,
  p_review_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_app public.school_applications%rowtype;
  v_tenant_id uuid;
  v_applicant_email text;
  v_note text;
begin
  if p_application_id is null or p_reviewer_id is null then
    raise exception 'Application and reviewer are required' using errcode = '22023';
  end if;
  if p_decision not in ('approve','reject') then
    raise exception 'Decision must be approve or reject' using errcode = '22023';
  end if;

  v_note := nullif(left(btrim(coalesce(p_review_note, '')), 1000), '');

  select * into v_app
  from public.school_applications
  where id = p_application_id
  for update;

  if not found then
    raise exception 'Application not found' using errcode = 'P0002';
  end if;
  if v_app.status <> 'pending' then
    raise exception 'Application has already been reviewed' using errcode = '55000';
  end if;

  if p_decision = 'reject' then
    update public.school_applications
    set status = 'rejected',
        review_note = v_note,
        reviewed_by = p_reviewer_id,
        reviewed_at = now()
    where id = v_app.id;

    return jsonb_build_object('application_id', v_app.id, 'status', 'rejected');
  end if;

  insert into public.tenants (name, slug, status)
  values (v_app.school_name, v_app.requested_slug, 'active')
  on conflict (slug) do nothing
  returning id into v_tenant_id;

  if v_tenant_id is null then
    raise exception 'Requested school code is already in use' using errcode = '23505';
  end if;

  select lower(btrim(u.email)) into v_applicant_email
  from auth.users u
  where u.id = v_app.applicant_user_id
    and u.email_confirmed_at is not null;

  if nullif(v_applicant_email, '') is null then
    raise exception 'Applicant must have a verified email address' using errcode = '22023';
  end if;

  insert into public.tenant_memberships (tenant_id, user_id, role, active)
  values (v_tenant_id, v_app.applicant_user_id, 'SCHOOL_ADMIN', true);

  -- The application owner must also have the school-admin profile required
  -- by the existing admin UI and tenant-aware QR Edge Function. The insert
  -- intentionally fails atomically if this email is already globally used
  -- in admin_users; multi-school admin profiles need a separate schema change.
  insert into public.admin_users (email, role, active, tenant_id)
  values (v_applicant_email, 'ADMIN', true, v_tenant_id);

  update public.school_applications
  set status = 'approved',
      review_note = v_note,
      reviewed_by = p_reviewer_id,
      reviewed_at = now()
  where id = v_app.id;

  return jsonb_build_object(
    'application_id', v_app.id,
    'status', 'approved',
    'tenant_id', v_tenant_id,
    'first_admin_user_id', v_app.applicant_user_id
  );
end;
$$;

revoke all on function public.review_school_application(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.review_school_application(uuid, text, uuid, text) to service_role;

commit;
