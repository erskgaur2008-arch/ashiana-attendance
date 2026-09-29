# Multi-tenant QA checklist

This checklist is for the `feat/multi-tenant-foundation` branch and the isolated EduPunch-Test Supabase project. Run these checks before merging or deploying multi-tenant changes.

## Safety rules

- Use only a dedicated test school, test accounts, and synthetic staff/attendance rows.
- Do not use real staff PINs, production credentials, or real attendance data.
- Do not run fixture inserts against production.
- Record the test date, branch commit, test account role, and outcome for each scenario.
- A SQL/RLS role simulation is useful evidence, but it does not replace an authenticated browser/API test.

## Workspace selection

- [ ] Sign in with an account that has one active membership. Confirm it opens that school directly.
- [ ] Sign in with a test account that has active memberships in two test schools. Confirm the workspace picker lists only those schools.
- [ ] Select each workspace and confirm the displayed school context and loaded records match the selection.
- [ ] Cancel with the Cancel button, Escape, and backdrop click. Confirm no workspace is entered and no stale school data remains visible.
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

Database-level RLS simulations have previously shown tenant-scoped reads for admin and staff roles, and their synthetic cross-tenant fixtures were rolled back. This is not a full two-tenant authenticated browser/API test. The current app includes a multi-workspace selection dialog during membership resolution; an always-available in-app workspace switch control is not yet verified as implemented.
