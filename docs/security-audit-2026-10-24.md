# Production database security audit — 2026-10-24

## Scope and safety

Read-only inspection of production project configuration, PostgreSQL grants and RLS policies, Supabase Storage bucket visibility/policies, and Supabase security advisor findings. No production data was modified during the audit.

## Confirmed observations

- Direct table grants to `anon` include broad privileges (including SELECT, INSERT, UPDATE, DELETE, and TRUNCATE) on 15 school tables: `admin_users`, `attendance_punches`, `attendance_qr_sessions`, `audit_logs`, `leave_requests`, `staff`, `student_attendance`, `student_calendar_events`, `student_class_assignments`, `student_homework`, `student_leave_requests`, `student_notices`, `student_report_cards`, `student_roster`, and `student_timetable`.
- The advisor reports 23 RLS-enabled tables without policies. RLS-enabled tables without policies normally deny API row access, but the combination of grants and no policies is confusing and should be hardened and reviewed table by table.
- The `staff-avatars` Storage bucket is public and has a public SELECT policy. This may be intentional for avatar rendering, but staff photos are personal data; review intended visibility and minimize data shown in avatars.
- The `student-portal-documents` bucket is public. The existing migration explicitly made it public so student portal PDFs can open without a Supabase Auth session. Treat this as a known exposure risk until the application is migrated to signed URLs or a session-authorized download endpoint. Do not flip the bucket to private before that compatibility work, because existing document links may break.
- `student-photos` and `fee-payment-proofs` buckets are private.
- Security advisor flags multiple SECURITY DEFINER functions executable by `anon`. Some are intentionally required for the custom Admission Number + DOB login flow and token-based student RPCs. Do not revoke their execution indiscriminately. Audit each function for token entropy/expiry, identity binding, rate limiting, search_path safety, and returned fields.
- Leaked-password protection is reported disabled. This should be enabled after reviewing the existing authentication model and testing the effect on account flows.

## Change proposed in this PR

A migration revokes direct anonymous table privileges from all 15 tables currently found with grants to `anon`. It does not modify rows, change authenticated grants, change Storage visibility, or revoke intended RPC execution. Existing SECURITY DEFINER RPCs should continue to work because their execution rights are separate from direct table grants.

## Required post-migration checks

1. Verify the 15 listed tables no longer grant table privileges to `anon`.
2. Verify student login, student session startup, student portal, attendance, staff login, administrator workflows, and fee submissions continue to work through their intended RPCs.
3. Use two test student accounts to confirm one session cannot read the other student's portal, attendance, leave requests, or fee data.
4. Test direct unauthenticated REST table reads/writes against the sensitive tables; expect denial.
5. Test that public document URLs are currently accessible only as an exposure confirmation in an approved test context; do not enumerate or download real personal documents.
6. Before making `student-portal-documents` private, update upload/read code to use short-lived signed URLs or a session-authorized download endpoint and test it end-to-end.
7. Decide whether staff avatars are meant to be public. If not, migrate consumers to signed URLs before changing the bucket to private.
8. Review all SECURITY DEFINER function definitions and explicit grants individually; no blanket revoke.
9. Enable leaked-password protection and run authentication regression tests.

## Production deployment status

This PR is a proposal only. Do not apply its migration to production until checks pass and the migration is reviewed. No production changes are made by this PR itself.

## Additional function-level finding from production review

- `student_login(p_school_code, p_enroll_no, p_dob_password)` is a `SECURITY DEFINER` function executable by `anon`. It returns a student object containing DOB, parent names, address, phone number, and photo path after validating the admission number and DOB-formatted password. The function currently applies a rate limit of six attempts per login key per 600-second window, which is useful protection, but the returned personal data is still broader than needed for an unauthenticated login response. Before changing its grants (which could break student login), plan a separate compatible change: return only the minimum login/session bootstrap fields, and retrieve additional student profile data through the session-bound `student_portal_bundle_by_session` RPC. Test existing ID card/profile screens before rollout.
- `student_session_start` creates a random 32-byte session token, stores its SHA-256 hash, and sets a 30-day expiry. This is a positive token design characteristic. Review session revocation, expiration enforcement, and whether token-bearing RPCs always bind every query to the student resolved from that token.
- `fee_submit_payment_by_session` validates the token, confirms the fee account belongs to the session's student, verifies the installment belongs to that account, caps the amount, checks remaining balance, and writes an audit record. These checks are useful; still test forged account/installment IDs and replayed UPI references with test data only.

## Revised recommendation

Do not merge/deploy solely because CI is green. First complete a test-environment compatibility run for the anonymous table grant revocation, and open a follow-up for minimizing the PII returned by the public student-login RPC. Do not blanket-revoke the session-based RPCs: the current custom student login and fee workflows depend on several of them.
