# Multi-tenant QA checklist

This checklist is for the `feat/multitenant-main-integration` branch / draft PR #3 and the isolated EduPunch-Test Supabase project. The branch is reconciled against current `main`; it is not deployed. Run these checks before merging or deploying multi-tenant changes.

## Safety rules

- Use only a dedicated test school, test accounts, and synthetic staff/attendance rows.
- Do not use real staff PINs, production credentials, or real attendance data.
- Do not run fixture inserts against production.
- Record the test date, branch commit, test account role, and outcome for each scenario.
- A SQL/RLS role simulation is useful evidence, but it does not replace an authenticated browser/API test.

## Workspace selection and switching

- [ ] Sign in with an account that has one active membership. Confirm it opens that school directly.
- [ ] Sign in with a test account that has active memberships in two test schools. Confirm the workspace picker lists only those schools.
- [ ] Select each workspace and confirm the displayed school context and loaded records match the selection.
- [ ] From the admin view, use the in-app switch control and confirm only active SCHOOL_ADMIN memberships in active tenants are offered.
- [ ] Switch between both test schools and confirm the school context, admin identity, staff list, and attendance data are refreshed for the selected tenant.
- [ ] Confirm the old realtime subscription is removed and no old-tenant data remains visible during or after switching.
- [ ] Confirm a switch is denied if membership is revoked or the target tenant is suspended before final membership revalidation.
- [ ] Confirm preflight failure preserves the current valid workspace, while failure after transition begins signs out and clears tenant state.
- [ ] Cancel with the Cancel button, Escape, and backdrop click. Confirm no unintended workspace is entered and no stale school data remains visible.
- [ ] Confirm suspended/inactive tenants and inactive memberships are not offered.
- [ ] Confirm a forged or stale tenant ID is rejected by membership resolution.
- [ ] Confirm a staff PIN login remains bound to the tenant of the matching staff record and cannot choose another tenant.

## Tenant data isolation

For each account, use synthetic records with unmistakably different labels in each test school.

- [ ] School A admin can read School A staff and attendance.
- [ ] School A admin cannot read School B staff, attendance, or admin profiles through the client/API.
- [ ] School B admin can read School B staff and attendance.
- [ ] School B admin cannot read School A staff, attendance, or admin profiles through the client/API.
- [ ] A staff account can read only its own tenant-scoped staff profile and permitted attendance data.
- [ ] Attempts to insert/update/delete rows with another tenant's `tenant_id` are rejected by RLS or trusted server-side checks.
- [ ] Realtime subscriptions do not deliver events from another tenant.
- [ ] Browser storage/cache keys are tenant-scoped; switching users or signing out does not reveal prior workspace data.

## Session and failure handling

- [ ] Sign out and confirm the current workspace and tenant-specific in-memory data are cleared.
- [ ] Sign out in another tab or expire the session; confirm the open tab clears the workspace.
- [ ] Force an admin login failure; confirm previous workspace data is not left on screen.
- [ ] Simulate a delayed sync, then sign out or change session; confirm the old request cannot repopulate the UI.
- [ ] Re-authenticate and confirm the user is asked to select a workspace again when appropriate.

## Evidence and release gate

- [ ] Capture browser/API results for both test tenants and all tested roles.
- [ ] Confirm no test fixtures remain after cleanup.
- [ ] Review Supabase Security Advisor and document accepted limitations.
- [ ] Confirm required database migrations are applied to the intended environment.
- [ ] Run available automated checks and inspect the GitHub Actions result.
- [ ] Do not describe the feature as production-ready until real authenticated multi-tenant browser/API tests pass and the release owner approves deployment.

## Current known coverage

Database-level RLS simulations have previously shown tenant-scoped reads for admin and staff roles, and their synthetic cross-tenant fixtures were rolled back. The in-app admin workspace switch control is included in the main-based integration branch and its key source paths have been reviewed, but it has not yet been exercised in a browser. EduPunch-Test currently has only one persistent tenant, so genuine two-school authenticated switching and cross-tenant browser/API isolation remain unverified.

## Elevated client privilege regression check

- [ ] After applying `20260929050000_revoke_elevated_client_table_privileges.sql` to an isolated test database, confirm `anon` and `authenticated` have no `TRUNCATE`, `TRIGGER`, or `REFERENCES` privileges on the listed public tables.
- [ ] Confirm intended `SELECT`, `INSERT`, `UPDATE`, and `DELETE` workflows still work according to each table's RLS policies.
- [ ] Confirm service-role maintenance and Edge Function workflows remain functional.
- [ ] Verify privilege state from PostgreSQL catalog queries; do not infer it from successful browser reads alone.

The migration has been applied to the isolated EduPunch-Test project only. Catalog checks confirmed `anon` and `authenticated` lack `TRUNCATE`, `TRIGGER`, and `REFERENCES` on all 11 listed tables; normal CRUD behavior still requires authenticated workflow testing. Production was not changed.

## Foreign-key index regression check

- [ ] After applying `20260929060000_index_unindexed_tenant_foreign_keys.sql` in an isolated database, confirm each of the six named indexes exists and matches its intended FK columns.
- [ ] Re-run the Supabase Performance Advisor and review remaining index and RLS-initplan findings.
- [ ] Compare representative query plans and monitor write overhead before any production rollout.

The index migration has been applied to EduPunch-Test only. PostgreSQL catalog checks confirmed all six indexes exist with the intended columns. Production was not changed; query-plan and write-overhead review remain release gates.

## Staff self-update column allowlist

- [ ] Apply `20260929070000_restrict_staff_self_update_columns.sql` only in an isolated test database.
- [ ] Confirm a staff account can update only `name`, `gender`, `dob`, `phone`, `address`, and `avatar_url` on its own active staff row.
- [ ] Confirm a staff account cannot change `emp_id`, `email`, `status`, `role`, `department`, `tenant_id`, PIN/hash fields, or any other column, including by sending direct API requests.
- [ ] Confirm staff cannot update another staff member's row, even in the same tenant.
- [ ] Confirm a SCHOOL_ADMIN can still edit tenant-scoped staff roster fields through the existing admin workflow.
- [ ] Confirm the staff profile form and profile-photo upload still succeed; verify failed attempts do not partially modify a row.
- [ ] Confirm trusted service-role Edge Function operations (PIN/email provisioning and profile changes) still work.

The allowlist includes `avatar_url` because the current staff profile-photo flow writes that field directly. The trigger migration has been applied to EduPunch-Test only. Catalog checks confirmed the `BEFORE UPDATE` trigger and `SECURITY DEFINER` function with an empty search path are installed. Authenticated staff/admin update attempts, profile/photo UI behavior, and service-role flows still require runtime testing. Production was not changed.

- [ ] Confirm a SCHOOL_ADMIN cannot change a staff row's primary key (`id`) or move it to another tenant (`tenant_id`), even when roster editing is otherwise authorized.

## Isolated Edge Function deployment check (2026-09-29)

- Read-only inspection found active EduPunch-Test deployments for `verify-attendance` (version 1), `reset-staff-pin` (version 1), `generate-attendance-qr` (version 3), and `review-school-application` (version 1). The deployed school-review function still authorizes the approver by a hard-coded email, while the current branch source requires an active `platform_admins` registry row. Therefore the test project's deployed review endpoint is not aligned with the reviewed branch source and must not be used to validate the current registry-backed onboarding flow.
- No function was deployed or invoked during this check. The active deployments must be reconciled with branch source and reviewed before endpoint testing. Do not deploy to production.
- Authenticated browser/API tests remain blocked until dedicated test-account sessions are available in a controlled browser/API environment; do not share passwords, PINs, service-role keys, or bearer tokens in chat.

## Initial EduPunch-Test browser checks (2026-09-29)

- User-reported successful sign-in and admin dashboard access for the dedicated test account. The supplied browser screenshot showed Supabase connection/auth and database RPC returning HTTP 200, a Supabase session present, Admin UI visible, a present non-expired access token, and the session email matching the admin record.
- User supplied a screenshot showing the Faculty & Staff Directory loaded with the synthetic staff record. A subsequent screenshot showed the staff dashboard for the test staff identity, with the session recognized but Admin UI disabled and the admin-email match false; this is consistent with role-specific UI separation in the observed session.
- The user reports that they checked the app and all tested functions were working. These are user-observed browser checks, not independently captured API traces or automated tests. Do not infer that every checklist item, two-tenant isolation, workspace switching, Edge Function parity, or production readiness has passed.
- All activity described here was against the isolated EduPunch-Test environment. No production deployment or database change was made. Two-school authenticated cross-tenant isolation and Edge Function reconciliation remain outstanding release checks.

## Edge Function source parity review (2026-09-29)

- Read-only source comparison: deployed `verify-attendance` v1 and `reset-staff-pin` v1 match their corresponding branch `index.ts` files byte-for-byte.
- Deployed `generate-attendance-qr` v3 differs from branch source. The deployed version explicitly extracts and validates the bearer token with Supabase Auth and resolves the user email by Auth user ID; the branch version relies on `ctx.userClaims`. This is a material implementation drift that needs review and a deliberate choice of intended source before deploying or testing endpoint parity. No function was deployed or invoked.
- Deployed `review-school-application` v1 differs from branch source: deployed authorization uses a hard-coded approver email; branch authorization checks the authenticated user's active `platform_admins` registry row. Keep this endpoint out of current onboarding validation until the test deployment is reconciled with reviewed source and an authorized test account exists.
- These are source-comparison results only. Exact source parity does not establish correct runtime behavior, and differing source does not alone prove exploitability. Test project only; production unchanged.
