

## Multi-workspace administrator consistency finding (2026-09-29)

- Read-only catalog inspection of EduPunch-Test shows `public.admin_users` has a primary-key/unique index on `email` alone, while the workspace-switch UI offers multiple active SCHOOL_ADMIN tenant memberships and validates an `admin_users` row for the selected tenant. With a globally unique admin email, one Auth email cannot have separate per-tenant `admin_users` rows; switching to a second tenant under the same identity can therefore fail its admin-profile check unless the data model and provisioning flow are changed. Confirm intended admin identity model before release.
- The current `reset-staff-pin` function also requires exactly one active membership total for an admin account. This conflicts with the app's multi-workspace admin flow if a user has multiple active SCHOOL_ADMIN memberships; staff create/reset/email operations should be reviewed for an explicit tenant context and membership validation rather than assuming a single membership.
- These findings are static/source and catalog analysis, not an attempted exploit or runtime failure. No schema or function was changed; EduPunch-Test only was inspected and production remains unchanged. Resolve the data-model/authorization contract and add two-tenant admin regression tests before release.


- Follow-up static review: deployed/branch `generate-attendance-qr` requires exactly one active SCHOOL_ADMIN membership for the user, so it will reject a legitimate multi-school administrator identity. The browser invokes this function without an explicit selected `tenant_id`; a tenant-aware correction should pass the selected workspace and validate that exact active membership, active tenant, and tenant-matched admin profile server-side. Keep fail-closed behavior and do not trust a caller-supplied tenant ID without membership validation. No deployment or runtime invocation was performed.
