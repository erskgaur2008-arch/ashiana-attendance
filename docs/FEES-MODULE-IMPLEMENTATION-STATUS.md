# Fees Management implementation status

## Branch and review

- Branch: `feat/live-fees-management`
- Draft PR: https://github.com/erskgaur2008-arch/ashiana-attendance/pull/241
- Status: draft only; not merged, not deployed, and not live.

## Draft files

- `supabase/migrations/20261023000100_fees_management_schema.sql`: additive fee tables.
- `supabase/migrations/20261023000200_fees_management_security.sql`: session-token-scoped student summary, submission, receipt and payment-status RPCs; Admin/Principal review queues; two-step confirmation; discount review; balance/duplicate-reference safeguards.
- `supabase/migrations/20261023000300_fees_management_storage.sql`: private payment-evidence bucket.
- `supabase/migrations/20261023000400_fees_management_admin_setup.sql`: audited Admin setup RPCs plus authorized academic-year listing, active-student search and fee-account search.
- `supabase/functions/fee-management/index.ts`: gateway for student fee summary, private proof upload/download, payment submission/status/receipts, Admin setup/search/review, discount approval and Principal confirmation. Browser CORS is allowlist-only via `FEE_ALLOWED_ORIGINS`.
- `supabase/config.toml`: sets `verify_jwt = false` for this one Edge Function because the student portal uses a custom session token in the body; all Admin/Principal operations still require Supabase Auth through server-side RPC checks.
- `index.html`: Student Portal fee summary, payment reference and proof submission, payment status/rejection reason, receipts, and Admin fee setup/review console with student/account search and discount approval queue.
- `supabase/tests/fees_management_security.sql`: database privilege/RLS assertions.
- `supabase/tests/fees_management_synthetic_bootstrap.sql`: mock Supabase dependencies and synthetic schema; no live data.
- `supabase/tests/fees_management_rpc_smoke.sql`: transactional synthetic student/Admin/Principal payment approval and receipt test, repeat-confirmation protection, rejected-payment no-ledger/no-receipt assertions, and discount approval/balance/audit assertions; rolls back its test data.
- `.github/workflows/fees-management-validation.yml`: Edge Function type-check, SQL parsing, inline JavaScript syntax validation, applies all four migrations to an isolated PostgreSQL 16 service, then runs security assertions and the synthetic payment smoke test.
- `docs/FEES-MODULE-PLAN.md`: product requirements and release safeguards.

## Validation so far

- All 12 inline JavaScript blocks in the current branch's `index.html` parsed successfully in a syntax check.
- The new fee console inline script parsed successfully.
- GitHub Actions run **#91 passed** on commit `45ed35d124a66a3c1c77d60259872c8884a1fd15`. Edge Function type-check, SQL parsing, all four migrations on isolated PostgreSQL 16, security assertions, and expanded synthetic RPC smoke tests passed. The expanded smoke test covers two-step confirmation, duplicate confirmation rejection, rejected-payment no-ledger/no-receipt behavior, discount balance calculation, and discount audit logging. Run #86 had exposed a malformed SQL test terminator; that was fixed before run #91.
- Edge Function type-check, SQL parser, required-feature checks, and inline JavaScript parsing passed.
- All four fee migrations applied successfully to an isolated PostgreSQL 16 test database using synthetic Supabase dependencies.
- The SQL security assertions passed, and the synthetic RPC smoke test passed: create academic year/fee structure/account, load student summary, submit a payment, Admin review, distinct Principal confirmation, one ledger credit/receipt, and duplicate-confirmation rejection.
- A date-validation regex bug in the academic-year and due-date inputs was corrected.
- This is isolated synthetic validation only. It is not a test against production schema or real uploads, devices, identities, push delivery, or UI end-to-end.

## Remaining before production

1. Finish browser UI usability checks for academic-year, student and fee-account search; verify the result labels against the live roster.
2. Verify real private proof upload/download end-to-end, including stored metadata and rejection of invalid uploads. The client now requests cleanup of an unsubmitted proof after a failed payment submission; this still needs real-browser verification.
3. Review the exact migration dependencies against production's schema without writing to production; only apply after explicit release approval, backup and rollback planning.
4. Expand synthetic tests for rejection/resubmission, duplicate references, concurrent/partial payments, discount limits, reversal entries and multi-year balances.
5. Identify and configure the actual Principal's authenticated user UUID; verify distinct Admin and Principal accounts.
6. Implement and verify scheduled fee reminders. Production has no confirmed scheduler; pending-review submissions must not be reminded as unpaid.
7. Set `FEE_ALLOWED_ORIGINS` to the approved exact web origins before deployment and test authorization for every action.
8. Run real-device regression tests for student session restoration, attendance, Admin/Teacher roles, notices and existing push notifications.
9. Prepare backup/restore and rollback instructions. Posted ledger entries and receipts must be corrected via audited reversal, not deletion.

## Accounting safeguard

UPI reference and screenshot are evidence, not settlement confirmation. Authorized reviewers must reconcile against the school's bank/UPI record. A ledger credit and receipt are created only after distinct Admin and Principal approvals.

## Release controls

Do not apply migrations to the live database, assign the live Principal approver, activate reminders, deploy functions, merge, or release an APK until the user explicitly approves the reviewed release.
