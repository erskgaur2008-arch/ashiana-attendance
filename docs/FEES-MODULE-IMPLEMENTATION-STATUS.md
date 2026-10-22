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
- `supabase/tests/fees_management_security.sql`: initial database privilege assertions.
- `.github/workflows/fees-management-validation.yml`: Edge Function type-check, required-file/feature checks and inline JavaScript syntax validation.
- `docs/FEES-MODULE-PLAN.md`: product requirements and release safeguards.

## Validation so far

- All 12 inline JavaScript blocks in the current branch's `index.html` parsed successfully in a syntax check.
- The new fee console inline script parsed successfully.
- GitHub Actions reported the latest Fees Management Draft Validation workflow as successful on commit `291ec628d592c3ece58b6b7ed2cc46744a9e28cf`, including the current Edge Function type check, feature-file assertions and inline JavaScript parser.
- The latest HTML/workflow changes were included in the successful validation run above.
- SQL has not been applied to a database. The SQL security test has not been run against a database.
- No end-to-end student/Admin/Principal test has passed yet.

## Remaining before production

1. Finish UI usability checks for the new academic-year, student and fee-account search controls; verify the search result labels match the live roster.
2. Verify proof upload end-to-end, including server-side verification of object metadata/content type after upload.
3. Verify the exact SQL against the live schema and run migrations only after explicit approval, backup and rollback planning.
4. Test all state transitions, rejection/resubmission rules, duplicate references, partial payments, discount calculations, receipts and reversals.
5. Configure the actual Principal's authenticated user UUID and prove separation using two distinct accounts.
6. Implement and verify scheduled fee reminders. Production has no confirmed scheduler; pending-review submissions must not be reminded as unpaid.
7. Tighten Edge Function CORS to the approved app origin and test authorization for every action.
8. Run security and regression tests for student session restoration, attendance, admin/teacher roles, notices and existing push notifications.
9. Prepare backup/restore and rollback instructions. Posted ledger entries and receipts must be corrected via audited reversal, not deletion.

## Accounting safeguard

UPI reference and screenshot are evidence, not settlement confirmation. Authorized reviewers must reconcile against the school's bank/UPI record. A ledger credit and receipt are created only after distinct Admin and Principal approvals.

## Release controls

Do not apply migrations to the live database, assign the live Principal approver, activate reminders, deploy functions, merge, or release an APK until the user explicitly approves the reviewed release.
