# Multi-tenant SaaS rollout

This branch is the isolated implementation track for converting EduPunch into a tenant-isolated attendance SaaS. Production Supabase and the `main` branch must remain unchanged until the complete authorization path is implemented and tested.

## Tenant model

- `tenants`: one school/customer workspace, identified by a stable slug.
- `tenant_memberships`: maps Supabase Auth users to a tenant and a tenant-scoped role (`SCHOOL_ADMIN` or `STAFF`).
- Existing business records receive a `tenant_id`; existing Ashiana records are backfilled to the `ashiana` tenant.
- Tenant selection is never trusted from browser input alone. The authenticated user's active membership must authorize the tenant on every request.

## Current branch state

- `20260928000000_multitenant_foundation.sql` creates the tenant tables and adds/backfills tenant identifiers.
- `20260928004000_create_staff_with_pin_tenant.sql` stages a service-role-only RPC that inserts a staff record with a validated active tenant ID and stores a bcrypt PIN hash. The Edge Function provisions the Auth user and membership as subsequent operations with best-effort cleanup; isolated failure-path testing is required because database and Auth changes are not one transaction.
- `20260928005000_tenant_scoped_staff_integrity.sql` stages non-null tenant ownership for tenantized business tables, replaces global employee-ID uniqueness with `(tenant_id, emp_id)`, and adds composite staff/tenant foreign keys for punches, leave requests, and ID cards. This depends on the foundation backfill and requires data-integrity validation before application.
- `20260928001000_seed_ashiana_memberships.sql` seeds memberships for existing Auth users whose email matches an active Ashiana admin or staff record.
- `20260928002000_school_applications.sql` adds an authenticated school-application queue. Applicants can submit and read their own pending/reviewed request; the designated approver email can read the queue when signed in. The approval Edge Function separately enforces that the Auth user has a confirmed email matching the designated approver. The RLS policy intentionally does not depend on a nonstandard `email_verified` JWT claim. Direct client updates/deletes and approval mutations are not granted.
- `20260928003000_school_application_review_rpc.sql` adds an atomic review/provisioning RPC, executable only by `service_role`. It locks the pending application, rejects repeated review, creates the tenant and applicant's first `SCHOOL_ADMIN` membership on approval, and updates review status in one transaction. The trusted Edge Function source at `supabase/functions/review-school-application/index.ts` validates the authenticated user through Supabase Auth and checks the designated, email-confirmed approver identity before calling the RPC. Both are staged source only; no migration was applied and no function was deployed. SQL/function behavior still requires isolated-environment validation.
- These migrations are committed to `feat/multi-tenant-foundation` only. They have **not** been applied to the production database.
- **Staff login flow staged:** the staff form now accepts School Code + Employee ID + PIN, or registered email + PIN. The branch-only `verify-attendance` source resolves employee IDs by active tenant slug, binds email lookup to the staff row tenant, validates active tenant/membership, and scopes attendance QR/punch lookups by tenant. The browser sends the school code and requires the response to include a tenant ID. This source is not deployed; compatibility, provisioning and login behavior still require isolated testing.
- Auth resolution and the primary frontend sync path are tenant-aware in this branch; staff and leave operations have tenant filters. Legacy unscoped browser cache and session-user hydration are disabled before authentication, and logout clears tenant memory and realtime subscription. Tenant-specific cache restore remains deferred until after trusted membership resolution. These client filters are not a security boundary.
- The production database was inspected read-only: existing business tables have RLS enabled but no `tenant_id` columns yet, confirming that the branch migrations remain unapplied. Existing policies include global `private.is_admin()` checks and email-based staff self-access; they must be replaced transactionally after tenant columns exist.
- The deployed Edge Functions were inspected read-only. Deployed code resolves admins/staff without tenant membership checks; `verify-attendance` has `verify_jwt=false` with custom bearer validation only on attendance action. Tenant-aware source copies of `verify-attendance`, `generate-attendance-qr`, and `reset-staff-pin` are now staged on this branch only. QR generation derives one active `SCHOOL_ADMIN` membership from the Auth identity, requires an active tenant and tenant-bound admin profile, and scopes QR session reads/updates/inserts by tenant. PIN reset now checks active membership/tenant for staff self-reset and school-admin operations, scopes target staff updates by tenant, and uses the staged `create_staff_with_pin_tenant` RPC, then creates the Auth user and active/inactive STAFF membership with cleanup attempts on downstream failure. This is not a single transaction across Postgres and Auth; reconciliation/isolated failure testing is required. The current database still has a global `emp_id` uniqueness constraint, so cross-school employee-ID reuse remains blocked until the planned uniqueness migration is staged and tested. None of these function sources are deployed; isolated validation is still required.
- Do not apply these migrations to production or merge this branch yet.

## Required implementation gates

1. **Auth and workspace resolution**
   - Resolve the signed-in Auth user to active memberships from the database.
   - Require explicit workspace selection if the user belongs to multiple schools.
   - Keep tenant identity in the session state, but revalidate membership server-side.
   - Remove any authorization dependence on browser storage or user-editable JWT metadata.

2. **Frontend tenant scope**
   - Add tenant/workspace selection and visible school identity.
   - Scope every read, insert, update, delete, realtime subscription, report, export, and cache key by the active tenant. Main sync and many staff/leave operations now carry tenant filters, but a full call-site and cache-read audit remains.
   - Clear tenant-scoped in-memory and local caches on logout or workspace switch. Unscoped cache hydration is disabled; authenticated tenant cache restore remains to be implemented and tested.
   - Do not treat a client-side `.eq('tenant_id', ...)` filter as a security boundary; it is only a usability filter.

3. **Database authorization**
   - Replace legacy global-admin policies with tenant membership-based policies for every business table.
   - Enforce immutable tenant ownership on updates and inserts.
   - Ensure staff self-service is restricted to their own staff identity and tenant.
   - Add tenant-aware unique constraints and foreign-key integrity where identifiers must be unique within a school.
   - Audit grants, including elevated table privileges, and verify no exposed table is unintentionally accessible.

4. **Edge Functions**
   - Update `verify-attendance`, `generate-attendance-qr`, and `reset-staff-pin` to validate the bearer user's active tenant membership and role. Tenant-aware source is staged for all three; isolated validation remains outstanding. `reset-staff-pin` now requires the caller's single active `SCHOOL_ADMIN` membership and active tenant, binds the admin profile and target staff operations to that tenant, and requires self-reset callers to have an active `STAFF` membership matching their staff row. A new `create_staff_with_pin_tenant` RPC now inserts staff with the validated tenant ID and is executable only by `service_role`. The Edge Function then provisions Auth and membership separately with best-effort compensation; cross-system atomicity and failure recovery require isolated tests. Existing global employee-ID uniqueness still needs migration to tenant-scoped uniqueness.
   - Derive tenant scope from validated membership, not caller-supplied tenant IDs.
   - Scope all service-role queries and mutations by tenant, staff identity, and relevant record ownership.
   - Return non-enumerating authorization errors and validate all request payloads.

5. **Verification before release**
   - Test two separate tenants with overlapping staff IDs/emails and verify there is no cross-tenant read or write.
   - Test staff self-access, school-admin actions, inactive memberships, suspended tenants, logout, workspace switching, QR expiry, and PIN reset.
   - Test legacy Ashiana workflows and data counts against a production backup or isolated Supabase development branch.
   - Review RLS policies and database advisors; inspect Edge Function logs and test on physical Android devices.
   - Apply migrations and deploy functions only after review and explicit production approval.

## Decisions / blockers requiring product-owner input

- **New-school onboarding (decided):** schools may submit a signup request, but a platform approver must approve it before a tenant and its first `SCHOOL_ADMIN` membership become active. The approver identity is set to `rajkumargaur54@gmail.com`; the approval interface, trusted approval/provisioning Edge Function, and first-admin verification flow still need implementation. The staged application queue is not yet wired to the frontend.
- **Staff identity (decided):** employee IDs may be reused by different schools; staff email addresses must remain globally unique. Existing `staff.id` is the primary key. The staged `20260928005000_tenant_scoped_staff_integrity.sql` removes global `emp_id` uniqueness, adds tenant-scoped uniqueness and composite tenant-consistent foreign keys. Staff email uniqueness remains globally required and must be audited alongside Auth identities before release.

## Product-owner decisions

- **Platform approver (decided):** `rajkumargaur54@gmail.com` is the designated platform school approver. This identity must be verified against the authenticated user on the server and must not be assignable through public signup or ordinary school-admin controls.
- **Staff login UX (decided):** allow either school code + Employee ID + PIN, or globally unique registered email + PIN. Employee ID lookup must be tenant-scoped; email lookup must enforce global uniqueness. The server must resolve the staff record and active tenant before validating the PIN. Employee ID lookup uses the school slug as the school code; registered email lookup is globally unique.

## Non-goals for this stage

No production schema changes, Edge Function deployments, auth-user creation, secrets changes, or merge to `main` are performed by this branch-only preparation.
