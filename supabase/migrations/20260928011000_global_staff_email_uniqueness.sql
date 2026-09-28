-- Enforce the product rule that staff login emails are globally unique.
-- Preflight duplicate normalized emails before applying; staged only.
-- Do not apply to production without isolated migration validation and rollout approval.
begin;

create unique index if not exists staff_email_normalized_unique_idx
  on public.staff (lower(btrim(email::text)));

commit;
