# Student session token correction — review status

This branch is isolated from production. The token migration and updated `student-photo-url` function were applied to EduPunch-Test only. Production has not been changed.

## Design
- Student login exchanges the submitted admission number and DOB for a random opaque bearer token.
- Only SHA-256(token), student UUID, expiry, revocation time, and last-used time are stored in the database.
- Android secure storage persists the token only; it must not persist DOB/password or reusable credentials.
- Session restore, portal bundle, leave submission, photo access, and logout use the session token.
- Token validation rejects malformed, expired, revoked, and inactive-student sessions.

## User-confirmed Android regression results (2026-10-14)
- Student login: **PASS**
- Fully close/reopen app and restore Dashboard: **PASS**
- Dashboard refresh: **PASS**
- Test leave request submission: **PASS**
- Student photo and ID card load: **PASS**
- Logout and fresh login: **PASS**
- Push notifications: **PASS**

## EduPunch-Test database security results (2026-10-14)
- Valid session restore and leave submission: **PASS**
- Malformed token rejection: **PASS**
- Expired token rejection: **PASS** (validator returned NULL)
- Revoked token rejection: **PASS**
- Inactive student rejection: **PASS** (temporarily changed a test student to INACTIVE, confirmed rejection, then restored ACTIVE)
- Direct SELECT on session-token table by anon/authenticated: **DENIED as intended**
- `student_session_student_id(text)` executable by service_role only: **PASS**
- New client RPCs (`student_session_start`, `student_session_revoke`, `student_portal_bundle_by_session`, `student_submit_leave_by_session`) executable by anon and not authenticated: **PASS**
- Temporary test tokens cleaned up; test student restored to ACTIVE: **PASS**
- Duplicate/overlapping pending leave-request runtime test: **PASS**. Two PowerShell jobs submitted overlapping dates concurrently through `student_submit_leave_by_session`; one returned success and the other returned `A leave request for these dates is already pending.` A read-only query confirmed exactly one pending matching row. The temporary session was revoked afterward. This proves serialization for concurrent calls through the session RPC, not for callers that bypass this RPC and invoke the legacy leave RPC directly.

## Read-only production compatibility review
- Production `student_login(p_school_code text, p_enroll_no text, p_dob_password text)` returns the student UUID at `student.id`.
- Production `student_portal_bundle(p_enroll_no text, p_dob_password text)` and `student_submit_leave(p_enroll_no text, p_dob_password text, p_from_date date, p_to_date date, p_reason text)` signatures match the compatibility calls.
- Existing production functions use SECURITY DEFINER with an empty search_path; the proposed RPCs use an empty search_path and schema-qualified objects.
- Production already has `student_leave_requests`, so the conditional fallback-table creation should not run there. Teacher approval/leave display still needs end-to-end testing before any rollout.
- No production schema, data, edge functions, or deployment was changed.

## Security advisor notes
EduPunch-Test still reports warnings for the existing legacy DOB-based `student_login` and `student_portal_bundle` SECURITY DEFINER RPCs, plus the intended anon-callable session RPCs. These legacy grants were not changed to avoid breaking existing web/PWA login. The new session RPCs have been explicitly revoked from `authenticated`; the token validator remains service_role-only. The token table has RLS enabled, no client policies, and client table grants revoked, which is intentional. Other advisor items include RLS-enabled tables with no policies and disabled Supabase Auth leaked-password protection; do not change these globally without a separate compatibility review and approval.

References:
- [RLS enabled without policies](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)
- [Anon can execute SECURITY DEFINER](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable)
- [Authenticated can execute SECURITY DEFINER](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)
- [Leaked password protection](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)

## Final review update (2026-10-14)
- Corrected `20261016_student_session_tokens_proposal.sql` to retain the per-student advisory transaction lock and overlap check, preventing the later migration from overwriting the earlier lock-protected function.
- Applied the corrected session-token migration to **EduPunch-Test only** using the isolated migration runner: **PASS**.
- Read-back verification confirms `student_submit_leave_by_session` contains `pg_advisory_xact_lock`; it remains `SECURITY DEFINER` with an empty search path; anon can execute the student-facing RPC while authenticated cannot.
- Read-back verification confirms `student_session_tokens` has RLS enabled and anon/authenticated do not have direct SELECT permission.
- Read-only query confirms exactly one pending TEST0001 row overlaps 2026-10-28–29 after the concurrent submission test.
- Latest GitHub commit status and PR-triggered workflow wrappers returned no status entries/runs. This is **not evidence that CI passed**. User-confirmed Android tests passed on the previously built test APK; no new APK build was verified for commit `81acc253cbeaad2f8147265210e60dfcb8e0f568`.

## Remaining release gates
1. Obtain an explicit CI result or run the relevant checks for the current PR head; do not infer green from missing status data.
2. Review push registration and student leave display paths for token-only session compatibility.
3. Before rollout, re-check production schema/function owners, extension schema, grants, and migration privileges read-only.
4. Take/verify a restorable production backup and record the current app/deployment revision before any approved rollout.
5. Only after explicit approval: apply the reviewed database migration first, deploy the matching edge function if required, then perform a controlled production regression.

## Rollback principles
- Keep the last known-good app/edge revision available.
- If a critical check fails, roll back app/edge deployment and diagnose before changing database objects.
- Do not automatically drop session tables/functions while clients may depend on them; any database cleanup requires a separate reviewed action.

## Current status
- Migration and edge function applied to EduPunch-Test only.
- Production Supabase and production deployment unchanged.
- PR #165 remains open and unmerged.
- This review record is not authorization to merge or deploy. Explicit rollout approval is required.
