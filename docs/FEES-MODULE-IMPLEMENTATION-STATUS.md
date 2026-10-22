# Fees Management implementation status

## Branch

`feat/live-fees-management`

## Files currently drafted

- `supabase/migrations/20261023000100_fees_management_schema.sql`: additive fee tables for academic years, fee structures, student accounts, installments, discount approvals, payment submissions, ledger, receipts, audit, principal approvers, and reminder attempts.
- `supabase/migrations/20261023000200_fees_management_security.sql`: student-session RPCs and Admin/Principal review RPCs.
- `supabase/migrations/20261023000300_fees_management_storage.sql`: private payment-evidence bucket.
- `supabase/tests/fees_management_security.sql`: initial database permission checks.
- `docs/FEES-MODULE-PLAN.md`: requirements, accounting rules, and release checklist.

## Not ready for production

These files are a first implementation draft, not a production-ready or activated fee module. No migrations have been applied and no Edge Functions have been deployed. The existing live website is unchanged.

Before release, complete and review:
1. Integrate student fee cards, payment submission, Admin review queue, Principal confirmation queue, discount management, and receipts into the current UI.
2. Implement a server-side Edge Function for proof uploads/downloads and authorized queue reads; keep the storage bucket private and do not grant direct object access.
3. Add narrowly scoped server-side admin operations to configure academic years, structures, installments, accounts, discounts, and principal approvers.
4. Validate existing production admin identity mapping and the exact existing `private.is_admin()` definition before relying on it.
5. Review whether student session tokens are passed and protected correctly by each RPC; never expose tokens, proof paths, or other students' fee records.
6. Ensure Admin rejection and Principal rejection semantics are consistent and allow resubmission without reusing a duplicate reference.
7. Add notification delivery with verified scheduler/dispatch mechanism; suppress reminders while a submission is pending review.
8. Run SQL parsing, migration dependency checks, permission tests, state-transition tests, and a complete regression review.
9. Produce a backup/restore and rollback plan. Never delete ledger entries or issued receipts; use audited reversals.

## Critical accounting safeguard

A screenshot and UPI reference are not proof of settlement by themselves. The authorized reviewers must reconcile the payment with the school's bank/UPI record. Only the two-step confirmation RPC creates a ledger credit and receipt.

## Release controls

Do not apply migrations to the live database, configure the live Principal approver, enable reminders, deploy functions, merge, or release an APK until the user explicitly approves the reviewed release.
