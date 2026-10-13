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

## Required before a test APK is approved
1. Review the token-only client integration for login, restoration, refresh, logout, leave submission, and student-photo authorization.
2. Ensure existing student push registration continues to work without persisting DOB/password.
3. Verify RPC grants and behavior under the actual Supabase test project.
4. Add automated checks for invalid, expired, revoked, and inactive-student sessions.
5. Build and test the isolated APK against EduPunch-Test.
6. Regression-test Admin/Staff login, student portal pages, logout, and live push configuration.
