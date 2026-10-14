# Student session token correction — review status

This branch is isolated from production. The token migration has been applied to EduPunch-Test only; production has not been changed.

## Why this is needed
The earlier Student session branch stored the admission number and DOB-derived password in Android secure storage. Secure storage protects data at rest, but persisting a reusable DOB credential is not the desired design.

## Proposed token design
- The existing student login check exchanges the submitted credentials for a cryptographically random bearer token.
- The database stores only SHA-256(token), the student UUID, expiry, revocation timestamp, and last-used timestamp.
- Session restore fetches the portal bundle using the token; the server rejects expired/revoked sessions and inactive students.
- Logout revokes the token server-side and removes it from Android secure storage.
- Token is the only persistent student session secret. Never store DOB/password in secure storage or localStorage.

## Important status
The SQL migration `supabase/migrations/20261016_student_session_tokens_proposal.sql` has been applied to EduPunch-Test only. It has not been applied to production. The `student-photo-url` function was also deployed to EduPunch-Test only.

## Test results (2026-10-14)
- Android app completely closed and reopened: **PASS** (user-confirmed; Student Dashboard restored).
- Student Dashboard refresh: **PASS** (user-confirmed).
- Test leave request submission: **PASS** (user-confirmed).
- Student photo / ID card preview: **PASS** (user-confirmed).
- Logout and fresh login: **PASS** (user-confirmed).
- Push notifications: **PASS** (user-confirmed).
- Android test APK build on the latest branch commit: **PASS**.
- Database token flow: valid token restore, leave submission, invalid token rejection, and revoked-token rejection were checked in EduPunch-Test.

## Before production rollout
1. Review this PR against the current `main` branch (main contains the prior PR #164 merge; this branch is one commit behind).
2. Review production schema/function compatibility and permissions; do not apply the migration to production yet.
3. Keep the production Supabase project and production deployment unchanged until the code review and rollout plan are approved.
4. After explicit approval, schedule the production migration/deployment and a post-deployment regression test.
