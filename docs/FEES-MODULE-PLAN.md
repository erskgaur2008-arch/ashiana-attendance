# Fees Management — Live Ashiana Attendance Web App

## Scope and safety

This feature branch targets the live application's codebase. It does not connect to, migrate, or write to the live database. No production data, existing attendance/authentication flows, secrets, deployed functions, or APKs are changed by this branch alone.

**Release gate:** migrations, storage bucket/policies, edge-function deployment, live reminder activation, merge, and production release require explicit approval after review.

## Confirmed requirements

- Multiple academic years.
- Fee structures and installment schedules.
- Student/parent view of assigned fees, paid amount, pending balance, and receipts.
- Payment submission requires UPI/reference ID and screenshot evidence.
- Two-person verification: Admin reviews first; a separately authorized Principal confirms second.
- The fee ledger and receipt are created only after both approvals.
- Admin can approve discounts, with reason and audit history.
- In-app and push reminders; suppress overdue/unpaid reminders while a payment is awaiting review.
- Private evidence storage and least-privilege access.
- Duplicate reference/idempotency safeguards and auditable corrections.

## Important accounting rule

A UPI reference ID and screenshot are supporting evidence, not confirmation that money reached the school's account. The authorized reviewers must reconcile with the bank/UPI record. Never issue a paid receipt or credit the ledger based only on a student submission.

## Implementation design

1. Add fee-specific tables without altering student identity tables; reference existing student UUIDs.
2. Use integer paise for all money values and database constraints for non-negative amounts.
3. Keep payment submissions separate from verified ledger entries. Record both approval actors/timestamps and prohibit the same actor from performing both steps.
4. Store evidence in a private bucket; issue only short-lived, authorized access URLs.
5. Use server-side RPCs/Edge Functions for state transitions. Do not rely on hidden UI buttons as authorization.
6. Keep Principal fee approval as a dedicated permission assignment, not a global role constraint change. Production principal identity must be explicitly mapped before enabling approvals.
7. Add reminders only after the scheduling mechanism is verified; current audit found no pg_cron/pg_net installed. Never enable an unverified scheduler.
8. Use an additive migration and reversible rollout. Corrections to posted payments must use reversal entries, not deletion.

## Release and verification checklist

- Inspect actual production migration state and current student-session authorization path before applying anything.
- Validate fee permissions, student isolation, private evidence access, and two-step approval.
- Test duplicate reference IDs, duplicate submissions, retries, partial payments, discounts, multiple academic years, and receipt numbering.
- Confirm pending review is excluded from overdue reminders.
- Regression-check student login/session refresh, attendance, teacher/admin roles, existing notices and push notifications.
- Confirm backup/restore and a written rollback plan before production migration.
- Do not use real student payments or fake ledger entries for testing.

## Open configuration needed before activation

The account/identity that should receive Principal confirmation must be explicitly assigned using the approved fee-specific permission mechanism. Do not infer it from the existing ADMIN/SUPER_ADMIN role.
