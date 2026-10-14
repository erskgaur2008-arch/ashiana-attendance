# Student session token correction — review status

This branch is isolated from production. The token migration has been applied to EduPunch-Test only; production has not been changed.

## Why this is needed
The earlier Student session branch stored the admission number and DOB-derived password in Android secure storage. Secure storage protects data at rest, but persisting a reusable DOB credential is not the desired design.

## Proposed token design
- The existing student login check exchanges the submitted credentials for a random bearer token.
- The database stores only SHA-256(token), the student UUID, expiry, revocation timestamp, and last-used timestamp.
- Session restore fetches the portal bundle using the token; the server rejects expired/revoked sessions and inactive students.
- Logout revokes the token server-side and removes it from Android secure storage.
- Token is the only persistent student session secret. Never store DOB/password in secure storage or localStorage.

## Test results (2026-10-14)
- Android app completely closed and reopened: **PASS** (user-confirmed; Student Dashboard restored).
- Student Dashboard refresh: **PASS** (user-confirmed).
- Test leave request submission: **PASS** (user-confirmed).
- Student photo / ID card preview: **PASS** (user-confirmed).
- Logout and fresh login: **PASS** (user-confirmed).
- Push notifications: **PASS** (user-confirmed).
- Student login succeeds: **PASS** (user-confirmed).
- Android test APK build on the synchronized branch commit: **PASS**.
- Database token flow: valid session restore, leave submission, invalid token rejection, and revoked-token rejection were checked in EduPunch-Test. Expired-token and inactive-roster cases have not been separately confirmed as test executions.

## Read-only production compatibility review (2026-10-14)
- The production `student_login(p_school_code text, p_enroll_no text, p_dob_password text)` function returns the student UUID at `student.id`, which matches the proposed session-start function's expected response shape.
- The production `student_portal_bundle(p_enroll_no text, p_dob_password text)` and `student_submit_leave(p_enroll_no text, p_dob_password text, p_from_date date, p_to_date date, p_reason text)` signatures match the proposed migration's compatibility calls.
- The existing production functions use `SECURITY DEFINER` and an empty `search_path`; the proposed new RPCs also use an empty `search_path` and schema-qualified objects.
- Production already has `student_leave_requests`; therefore the migration's conditional fallback table creation should not run there. The existing leave RPC writes `teacher_email` and returns a JSON result; production-specific post-deploy testing must confirm teacher approval/leave display still works end-to-end.
- The Supabase security advisor flags exposed `SECURITY DEFINER` functions, including the new test RPCs and older student login/bundle/leave RPCs. This is a warning to review exposure and grants, not a reason to indiscriminately revoke legacy permissions. The token table is RLS-enabled with no direct policies and has client table grants revoked; access is intended to occur through carefully scoped RPCs.
- Production checks above were read-only. No production schema, data, edge functions, or deployments were changed.

## Remaining security gates before rollout
1. Review all proposed RPC grants and `SECURITY DEFINER` behavior, including how `student_session_student_id` is restricted to `service_role` and called internally by owner-executed functions.
2. Test expired token, inactive/passout student, malformed token, repeated leave request, and logout/revocation behavior in EduPunch-Test.
3. Verify student push registration continues to work without relying on a stored DOB credential; existing push behavior passed the current user test, but review its credential path before release.
4. Confirm production function owners, extension schema, migration privileges, and actual grants using read-only catalog queries immediately before rollout.
5. Run the release only in a planned window after explicit approval; deploy the database migration before client code that depends on the new RPCs, then deploy the matching edge function if needed.

## Proposed release and rollback plan (not executed)
1. Take/verify a restorable production database backup and record the current production app/deployment revision.
2. Apply the reviewed migration to production only after explicit approval; do not modify or revoke the legacy student RPCs as part of this migration.
3. Deploy the matching `student-photo-url` edge function only after reviewing its production compatibility and confirming its environment configuration.
4. Run a controlled post-deploy regression: student login, close/reopen, refresh, attendance/portal data, leave submission and teacher review, photo/ID card, push notifications, logout, and fresh login.
5. If any critical check fails, roll back the app/edge deployment to the last known-good revision and diagnose before changing database objects. Do not drop the session table/functions as an automatic rollback while clients may still be using them. Database cleanup, if ever needed, must be a separate reviewed action after confirming no clients depend on them.

## Important status
- SQL migration and updated `student-photo-url` function were applied to EduPunch-Test only.
- Production Supabase and production deployment have not been changed.
- PR #165 remains open and unmerged. This document is a review record, not production approval.
- Obtain explicit rollout approval before applying the migration or deploying production changes.
