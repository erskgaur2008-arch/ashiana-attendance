# Fees Management implementation status

## Branch and review

- Branch: `feat/live-fees-management`
- Draft PR: https://github.com/erskgaur2008-arch/ashiana-attendance/pull/241

## Draft files

- `supabase/migrations/20261023000100_fees_management_schema.sql`: additive fee tables.
- `supabase/migrations/20261023000200_fees_management_security.sql`: student session summary/submission/receipt RPCs, Admin and Principal review queues, two-step confirmation, discount review.
- `supabase/migrations/20261023000300_fees_management_storage.sql`: private evidence bucket.
- `supabase/functions/fee-management/index.ts`: gateway for student summaries, proof upload URL creation, payment submission, receipts, authorized review queues, temporary proof viewing, Admin review and Principal confirmation.
- `supabase/tests/fees_management_security.sql`: initial database privilege assertions.
- `.github/workflows/fees-management-validation.yml`: Deno type check and required-file checks.
- `docs/FEES-MODULE-PLAN.md`: product requirements and release safeguards.

## Not ready for production

This is a code draft, not a live/activated feature. SQL has not been applied and the Edge Function has not been deployed. The existing live web UI has not yet been integrated, and no production data has been modified.

Before merge/release:
1. Integrate student fee cards, payment upload/submission, Admin queue, Principal queue, discount controls, and receipt display into the existing `index.html` without disturbing login/attendance code.
2. Complete and test proof upload with an actual signed-upload flow; validate object metadata/content type after upload and before accepting the submission.
3. Add secure admin operations for academic-year setup, fee structures, student fee account assignment, installment configuration, discount request creation, and Principal permission assignment.
4. Verify SQL syntax and dependencies against the exact live schema. Check all roster columns, auth helpers, extensions, and RLS/role semantics.
5. Test all state transitions, rejection/resubmission rules, duplicate UPI references, partial payments, discount calculations, receipts, and reversals.
6. Ensure every review and download action is restricted server-side and every proof link is short-lived.
7. Add reminders only after a supported scheduler is selected; pending-review submissions must not be reminded as unpaid.
8. Add full security and regression tests for student session restoration, attendance, admin/teacher roles, notices, and existing push notifications.
9. Prepare backup/restore and rollback instructions. Posted ledger entries and receipts must be corrected via audited reversal, not deletion.

## Accounting safeguard

UPI reference and screenshot are evidence, not settlement confirmation. Authorized reviewers must reconcile against the school's bank/UPI record. A ledger credit and receipt are created only after distinct Admin and Principal approvals.

## Release controls

Do not apply migrations to the live database, assign the live Principal approver, enable reminders, deploy functions, merge, or release an APK until the user explicitly approves the reviewed release.
