# Student session token correction — review status

This branch is isolated from production. No database migration is applied by this change.

## Why this is needed
The earlier Student session branch stored the admission number and DOB-derived password in Android secure storage. Secure storage protects data at rest, but persisting a reusable DOB credential is not the desired design.

## Proposed token design
- The existing student login check exchanges the submitted credentials for a cryptographically random bearer token.
- The database stores only SHA-256(token), the student UUID, expiry, revocation timestamp, and last-used timestamp.
- Session restore fetches the portal bundle using the token; the server rejects expired/revoked sessions and inactive students.
- Logout revokes the token server-side and removes it from Android secure storage.
- Token is the only persistent student session secret. Never store DOB/password in secure storage or localStorage.

## Important status
The SQL file `supabase/migrations/20261016_student_session_tokens_proposal.sql` is a **proposal** only. It has not been applied to EduPunch-Test or production. It is not ready to merge or deploy yet.

## Required before a test APK is approved
1. Finish client integration for login, restoration, refresh, logout, leave submission, and student-photo authorization.
2. Ensure existing student push registration continues to work without persisting DOB/password.
3. Review PostgreSQL extension/schema assumptions and verify RPC grants under the actual Supabase project.
4. Add automated checks for invalid, expired, revoked, and inactive-student sessions.
5. Apply the migration only to EduPunch-Test with explicit operator action, then build and test the isolated APK.
6. Regression-test Admin/Staff login, student portal pages, logout, and live push configuration.
