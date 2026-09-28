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
- `20260928006000_tenant_membership_rls.sql` stages replacement of legacy global-admin/email policies with active tenant membership policies for admin, staff, attendance, leave, audit, QR and ID-card tables. It uses narrowly scoped `private` SECURITY DEFINER helpers that derive the Auth identity from `auth.uid()`/JWT email and require active tenant membership. Policy behavior, grants and helper execution must be verified on an isolated database before use.
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
   - `20260928006000_tenant_membership_rls.sql` stages membership-based policies for the current known business tables. Review it against the complete live schema, grants, and any additional policies before applying.
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


## Additional static review findings (2026-09-28)

- A source review found over-escaped PIN and email validation regexes in the staged `reset-staff-pin` `create_staff` branch. These have been corrected in the branch source; compilation and runtime behavior are not yet tested.
- Live read-only grant inspection showed broad table privileges for `anon` and `authenticated` on the known business tables. Migration `20260928007000_revoke_anon_business_table_grants.sql` stages revocation of all anonymous privileges on those tables as defense in depth. It has not been applied. Authenticated grants still need least-privilege review; RLS policies alone do not restrict which columns a permitted UPDATE can modify.
- The staged `tenant_staff_self_update` policy constrains the row to the signed-in staff email and tenant, but does not constrain changed columns. Before release, either remove staff self-update if not required or enforce an explicit safe-column allowlist (for example through carefully reviewed column privileges or a trigger). Keep administrator update workflows functional.
- The known live public business tables are RLS-enabled, but RLS is not forced. Service-role and table-owner behavior, all non-public schemas, views, RPCs, storage policies, and grants need a separate exposure audit.
- No isolated database has been provisioned and no migration/function has been executed for testing. These changes are static-review findings only and are not release approval.


- A read-only RPC exposure review found `verify_staff_pin(text,text)` executable by `anon` and `authenticated` in the current database. Although its current JWT-email condition limits successful checks, anonymous execution is unnecessary. Migration `20260928008000_tenant_scoped_pin_rpc.sql` stages revoking anonymous execution and replacing `set_staff_pin` with tenant-aware authorization for the signed-in staff member or an active same-tenant school admin. Static review confirmed the internal PIN setter is `SECURITY DEFINER` but not executable by `authenticated`; the wrapper was therefore updated to `SECURITY DEFINER` with an empty `search_path`, while retaining explicit Auth identity, target staff, and same-tenant role checks before calling the internal function. This narrows the privilege bridge but must still be validated in isolation for self-change/admin-reset flows.

- A read-only storage review found `staff-avatars` is a public bucket with a public-read policy and authenticated upload/update/delete policies keyed to the Auth user ID as the first object-path segment. The frontend stores avatar URLs in `staff.avatar.avatar_url` and uses public URLs. This means avatar images are intentionally publicly retrievable and not tenant-private; decide whether this is acceptable profile-photo behavior or convert to private tenant-scoped storage with signed URLs before onboarding other schools. No storage policies or bucket settings were changed.

- Platform onboarding static review: the school-application table permits authenticated applicants to submit requests tied to their own Auth UID/email and read only their own rows; the configured approver can read the queue. Direct updates/deletes are revoked, and review/provisioning is exposed only through the service-role RPC invoked by an Edge Function that checks the confirmed approver identity. Static review did not identify an obvious applicant-side approval bypass. Validate slug collisions, duplicate applications, RPC ownership/search_path, and edge-function behavior in an isolated environment.
- **Avatar privacy decision (approved for implementation):** profile photos should become private and tenant-scoped rather than publicly readable. This requires a coordinated staged storage migration and frontend changes: preserve/migrate existing object paths, write tenant-scoped object paths, replace public URLs with authenticated signed-URL resolution, and align read/write/delete policies with active tenant membership. Do not flip the live bucket to private until legacy URL conversion and UI rendering have been implemented and tested together.


## Private staff-avatar implementation audit (2026-09-28)

- The live `staff-avatars` bucket was inspected read-only and remains public, with a 2 MiB limit and JPEG/PNG/WebP MIME allowlist. The live `storage.objects` policies include public SELECT for the entire bucket and authenticated insert/update/delete constrained only by the first path segment matching `auth.uid()`.
- The branch frontend currently uploads to a user-ID-first path, calls `getPublicUrl()`, stores the resulting public URL in `staff.avatar_url`, and renders that URL directly. Avatar values are loaded during auth/session resolution, staff sync and staff login.
- Static source audit identified direct photo rendering in the shared avatar renderer, bulk staff ID-card HTML, staff ID-card preview, and staff ID-card generation. All must be converted to private signed-URL resolution before the bucket can be made private.
- **Do not flip the bucket or replace live storage policies as part of a standalone migration.** SQL cannot move existing Storage object bytes. A safe rollout must first support both legacy public URL values and new private object paths, migrate/copy legacy objects through Storage APIs, verify every referenced object and all image render paths, then make the bucket private and remove public-read access in a separately approved deployment sequence.
- Proposed new object key convention: `{tenant_uuid}/{auth_user_uuid}/profile-{unique_suffix}.{ext}`. Authorization should verify active membership in the tenant and constrain object access to a staff avatar row in that same tenant; do not trust a tenant ID supplied by the browser. Decide and document whether all active school members may read staff avatars (needed for rosters/ID cards) or whether visibility is restricted further.
- This is an audit checkpoint only. No avatar frontend changes, storage policy changes, bucket setting changes, data migration, or production writes were made. Branch and production remain unchanged by this checkpoint.


## Avatar frontend flow audit (2026-09-28)

- Staff avatar values are read in Auth session resolution, staff cloud sync, admin staff-directory loading, and staff PIN login. The branch currently treats `staff.avatar_url` as a directly renderable URL and copies it into in-memory staff records; staff login's initial `currentAuthUser` object also needs its tenant metadata aligned with the trusted membership resolved after Auth sign-in.
- Avatar display paths include the shared profile/nav avatar renderer, bulk ID-card HTML, the staff's own ID-card preview, and individual staff ID-card printing. These ID-card paths build HTML synchronously from the current avatar value; private storage support must resolve signed URLs before HTML is generated and should handle URL expiry during long print sessions.
- Upload currently uses `{auth_user_id}/profile-{timestamp}.{ext}`, stores a public URL, and updates the current tenant's staff row. New private object keys should encode both tenant and Auth user identity, with membership and staff-row authorization enforced by Storage RLS—not by client path construction alone.
- Implementation remains gated on an explicit product access rule: whether any active member of a school may read all staff profile photos (to support school directory and ID-card printing), or only the photo owner and authorized school administrators may read them. Until this is resolved, do not author Storage read policies or alter bucket visibility.
- No frontend avatar logic, storage objects, bucket settings, or live policies were changed in this checkpoint.


## Private tenant-scoped staff-avatar implementation (branch-only)

- Storage write-policy hardening: tenant-prefixed object paths must contain exactly two folder segments (tenant UUID / caller Auth UID) and uploads, updates, and deletes require an active staff row whose email matches the authenticated JWT in that tenant. This narrows writes beyond membership-only checks; policy behavior still requires isolated integration tests.

- Follow-up during implementation: staff PIN login now resolves the signed-in Auth user's trusted active membership and verifies its tenant ID/STAFF role against the tenant ID returned by the attendance verification function before setting the active workspace. This supplies the tenant context required for the tenant-prefixed avatar upload path. Runtime validation remains pending.

- Product access rule confirmed: **all active members of a school may view staff photos** within their own active tenant.
- Frontend upload now uses `{tenant_uuid}/{auth_user_uuid}/profile-{timestamp}.{ext}` and stores the returned Storage object path in `staff.avatar_url` instead of a public URL. The frontend signs object paths on demand for rendering, with a short in-memory URL cache; signed URLs are not written to sessionStorage/localStorage or the staff row.
- Legacy `staff.avatar_url` public URLs are supported by extracting the object key only from the known Supabase public Storage URL route, then requesting a signed URL for that key. This allows existing objects to remain in place when the bucket is made private, provided each referenced object still exists and the stored URL matches the current Storage route.
- Shared avatar rendering and staff ID-card preview/printing now resolve signed URLs before embedding them. Bulk ID-card printing resolves photos before building printable card HTML. A failed signed-URL lookup falls back to staff initials rather than rendering a public URL directly.
- `20260928009000_private_tenant_staff_avatars.sql` stages the private bucket setting and tenant-member Storage policies. New-path reads require an active STAFF or SCHOOL_ADMIN membership for the tenant UUID in the object path. Legacy-path reads use a narrowly scoped private-schema SECURITY DEFINER boolean helper that derives the caller from `auth.uid()` and checks the avatar row's tenant membership. Uploads require an active STAFF membership, a matching active staff email, and the caller's own Auth-UID folder. New-path update/delete are restricted to the caller's own tenant-prefixed folder; legacy objects are intentionally not mutable through the new policy.
- **Verification remains outstanding:** no production migration was applied, no Storage objects were moved, and no bucket/policy changes were made live. The frontend and SQL have not been runtime-tested together in an isolated Supabase project. Before release, validate Storage RLS for same-tenant staff/admin, cross-tenant users, suspended tenants/memberships, legacy public-URL rows, missing objects, and upload/update/delete behavior. Ensure the private helper's owner/privileges and the Storage API policy evaluation are verified in an isolated environment.
- Deployment sequencing is important: deploy compatible frontend and tenant schema/policies in a coordinated release, verify legacy URLs map to real object keys, then apply the private bucket migration. If the migration is applied before compatible frontend code is active, previously public URLs will stop loading in older clients.


- **Follow-up frontend scope audit:** realtime subscriptions are now created only after a verified active workspace is present, use a tenant-specific channel name, and apply a `tenant_id=eq.<workspace>` filter to staff, attendance-punch, and leave-request events. The callback still performs tenant-filtered cloud sync; RLS remains the authorization boundary. Staff ID-card issuance upserts now use the composite `tenant_id,staff_id` conflict key to align with tenant-scoped records. These source changes are branch-only and have not been runtime-tested against Supabase Realtime or the target unique constraint.

- **Realtime lifecycle follow-up:** code inspection found initialization occurs before authentication, so the tenant-aware subscription would return without connecting and was not reliably re-established after login/session restore. The frontend now attaches the subscription after staff/admin login and restored sessions, and removes it before logout clears tenant context. This is statically inspected only; verify channel subscribe/unsubscribe behavior with Supabase Realtime integration tests.


- **Tenant cache initialization audit:** staff login previously persisted the matched staff row before assigning the verified tenant context, which could write it under the legacy browser-cache key. The branch now sets the verified tenant and authenticated workspace first, initializes `persistedTenantId`, and only then persists the staff row. This is a source-level correction; browser login/restore and cache-isolation behavior still need runtime coverage.

- **Cloud mutation consistency audit:** several legacy UI actions remain optimistic and do not inspect Supabase mutation errors before showing success or finalizing local state. This includes bulk staff deletion, leave approval/rejection/submission, and the admin quick-punch path. Tenant filters are present on the inspected staff/leave writes, but filtered writes and swallowed errors can still leave browser state inconsistent with cloud state or conceal RLS/constraint failures. Before release, convert these actions to await and check each Supabase result, then commit local state/show success only after confirmed cloud success (or explicitly mark a queued/offline state and provide retry/reconciliation). Test partial bulk-delete failures, staff RLS restrictions, duplicate/constraint errors, and network interruption.


- **Bulk deletion consistency follow-up:** both bulk staff deletion entry points now require a verified admin cloud workspace, issue one tenant-filtered delete for the selected IDs, inspect the returned error and deleted IDs, and update local roster/cache/audit UI only after the backend confirms every selected row was deleted. Failures remain visible and preserve the local roster for refresh/retry. Static review only: validate PostgREST delete-returning behavior with the deployed grants/RLS, composite foreign-key restrictions, and partial/zero-row outcomes in an isolated integration environment.


- **Leave-decision consistency follow-up:** approve/reject handlers now require a verified admin tenant session, await the tenant-filtered Supabase update, and verify a row was returned before changing local status, caching, audit display, or success feedback. Backend errors leave local status unchanged and are surfaced to the administrator. Static review only; validate UPDATE ... RETURNING under the actual RLS/grants and concurrent decision behavior in isolation.


- **Staff update confirmation follow-up:** self-service profile edits and administrator staff edits now request the affected row and treat a zero-row result as failure before changing local state or showing success. Static review only; verify PostgREST UPDATE ... RETURNING behavior with the deployed RLS policies and grants in an isolated environment.

- **Single staff deletion consistency follow-up:** the individual delete action now requires a verified administrator tenant workspace, awaits the tenant-scoped delete, checks the returned row/error, and only then removes the staff member from local state or reports success. Failed/zero-row deletes preserve the local roster and surface an error for refresh/retry. Static review only; validate DELETE ... RETURNING under deployed RLS/grants and staff foreign-key restrictions in an isolated environment.

- **Attendance/leave write consistency follow-up:** admin quick-punch and manual correction now require a verified administrator tenant session and persist the tenant-filtered punch to Supabase before changing the local ledger or showing success. Staff leave submission now requires a verified staff tenant session, validates date order, awaits the tenant-scoped insert, and only then updates local state and reports success. Failed cloud writes are surfaced without optimistic local mutation. Static source review only; validate schema columns, RLS insert/update grants, returned errors, and duplicate/concurrent requests in isolated integration tests.


## Staff provisioning and PIN failure-recovery audit (2026-09-28)

- Static review of individual staff creation found that the Edge Function creates the tenant-scoped staff row, Auth user, and membership, after which the browser performs a separate profile update for phone, address, and ID validity. If that second update fails, the server-side staff/Auth/membership records already exist while the UI reports creation failure and does not add the staff row locally. This can leave a valid but partially completed staff profile; resolve by moving optional profile fields into the trusted provisioning RPC/Edge Function or adding a narrowly authorized retry/reconciliation flow before release.
- Static review of staff PIN changes found the database PIN hash is changed before the corresponding Supabase Auth password update. If the Auth update fails, the stored attendance PIN and Auth password can diverge. The admin/self-service PIN reset Edge Function has the same cross-system ordering in some paths. Design and test a recovery/compensation strategy (including Auth update failures and retries) in an isolated environment before release; do not claim cross-system atomicity.
- These are static findings only. No runtime test, production change, or migration execution was performed.


## Staff provisioning improvement (2026-09-28)

- Added staged migration `20260928010000_staff_provision_profile_atomic.sql`, replacing the earlier nine-argument `create_staff_with_pin_tenant` RPC with a service-role-only signature that also accepts phone, address, and valid_thru. The initial staff insert now stores those optional profile fields together with the staff row and PIN hash.
- The trusted `reset-staff-pin` Edge Function passes the validated administrator's tenant ID and supplied profile fields to the RPC. The individual staff-create form no longer performs a second browser-side profile update after account creation, removing the previously identified partial-profile failure window.
- Excel import continues to omit optional profile fields and relies on the RPC defaults.
- This improves database-row consistency but does not make PostgreSQL, Supabase Auth user creation, and tenant-membership insertion one distributed transaction. Existing best-effort cleanup and failure recovery still require isolated tests.
- PIN changes remain a cross-system consistency risk: the stored PIN hash and Auth password are updated separately. A safe operational retry/reconciliation approach and failure-injection tests are still required before release.
- Static implementation only. Migration and function are not deployed or runtime-tested; verify function signature, date casting, column types, grants, rollback paths, and Auth/membership cleanup in an isolated environment.


- **Global staff-email consistency follow-up:** the administrator email-change path now validates the full email shape and checks for duplicates across all tenant staff records, rather than only within the administrator's own tenant. This aligns the pre-check with the product decision that staff email addresses are globally unique; database/Auth uniqueness and rollback behavior still require isolated integration tests. Branch-only static change; not deployed or runtime-tested.


- **Database enforcement for global staff email uniqueness:** added staged migration `20260928011000_global_staff_email_uniqueness.sql`, creating a unique index on normalized staff email (`lower(btrim(email::text))`). A read-only inspection of the current live `staff` table found no duplicate normalized staff emails at the time of inspection. This is only a preflight observation, not a guarantee that the index will build later; rerun the duplicate check immediately before any approved migration. Validate lock/build behavior and all create/change/import flows in an isolated database. The migration is not applied to production.


- **PIN reset retry behavior improvement:** the admin and self-service PIN reset paths now update the derived Supabase Auth password before writing the attendance PIN hash. If the database update fails or returns false after Auth succeeds, the Edge Function returns `PIN_AUTH_SYNC_PENDING` with instructions to retry the exact same PIN; reapplying that value is intended to converge both stores. This changes the failure window rather than providing distributed atomicity: until a retry succeeds, Auth may accept the new PIN while attendance verification still has the previous hash. The self-service recovery session may expire, and no durable reconciliation queue or automatic repair worker exists. Validate retry behavior, response propagation to the UI, simultaneous reset attempts, Auth outage, DB outage, and newly-created Auth account cases through failure-injection tests in an isolated environment. Branch-only; not deployed or runtime-tested.

- **Email validation audit correction:** a source review found the `update_staff_email` branch's email regex was double-escaped in the JavaScript regex literal, so it did not implement the intended whitespace/dot checks. Corrected it to the standard whitespace-aware pattern. This is a static source fix; validate normal, malformed, whitespace-containing, and boundary-case addresses in automated tests before release.
