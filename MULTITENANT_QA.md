

## Multi-workspace administrator consistency finding (2026-09-29)

- Read-only catalog inspection of EduPunch-Test shows `public.admin_users` has a primary-key/unique index on `email` alone, while the workspace-switch UI offers multiple active SCHOOL_ADMIN tenant memberships and validates an `admin_users` row for the selected tenant. With a globally unique admin email, one Auth email cannot have separate per-tenant `admin_users` rows; switching to a second tenant under the same identity can therefore fail its admin-profile check unless the data model and provisioning flow are changed. Confirm intended admin identity model before release.
- The current `reset-staff-pin` function also requires exactly one active membership total for an admin account. This conflicts with the app's multi-workspace admin flow if a user has multiple active SCHOOL_ADMIN memberships; staff create/reset/email operations should be reviewed for an explicit tenant context and membership validation rather than assuming a single membership.
- These findings are static/source and catalog analysis, not an attempted exploit or runtime failure. No schema or function was changed; EduPunch-Test only was inspected and production remains unchanged. Resolve the data-model/authorization contract and add two-tenant admin regression tests before release.


- Follow-up static review: deployed/branch `generate-attendance-qr` requires exactly one active SCHOOL_ADMIN membership for the user, so it will reject a legitimate multi-school administrator identity. The browser invokes this function without an explicit selected `tenant_id`; a tenant-aware correction should pass the selected workspace and validate that exact active membership, active tenant, and tenant-matched admin profile server-side. Keep fail-closed behavior and do not trust a caller-supplied tenant ID without membership validation. No deployment or runtime invocation was performed.


## Multi-school admin support implementation (2026-09-29)

- Added `20260929080000_multischool_admin_profiles.sql` to replace the email-only `admin_users` primary key with a composite `(tenant_id, email)` primary key, enforce non-null tenant association, and add case-insensitive email uniqueness within each tenant. The migration intentionally aborts if any admin row has a null tenant or duplicate normalized email within one tenant.
- Applied the schema migration to isolated EduPunch-Test only. Read-only catalog verification confirmed `PRIMARY KEY (tenant_id, email)`, the `admin_users_tenant_email_lower_uidx` unique index, zero null tenant IDs, and two existing admin rows. Production was not changed.
- Updated `reset-staff-pin` to require a syntactically valid requested `tenant_id`, validate the authenticated user's active SCHOOL_ADMIN membership for that exact tenant, verify the tenant is active, and load the matching active admin profile scoped to that tenant. It no longer requires the administrator to have exactly one active membership.
- Updated `generate-attendance-qr` to accept the selected tenant context and validate an active SCHOOL_ADMIN membership for that exact tenant before creating or retrieving that tenant's QR session. It no longer rejects admins solely because they manage multiple schools.
- Updated the shared browser Edge Function invocation helper to attach the current selected `tenant_id` for authenticated admin requests. The tenant ID is only a selector; server-side membership/profile checks remain authoritative. Updated the school approval RPC comment to reflect tenant-scoped admin profiles.
- Source edits are committed to the development branch. No Edge Function has been deployed or invoked. Runtime tests for two-school switching, cross-tenant rejection, staff create/reset/email update, QR generation, and application approval are still required. Reconcile deployed function versions before testing endpoints; do not deploy to production.
