# Multi-school authorization design

## Status
Design checkpoint only. This document does not change the production database, deploy functions, or enable additional schools. The current student attendance UI remains scoped to the APS school code `ashiana`.

## Goals
- Enforce tenant boundaries in PostgreSQL Row Level Security (RLS), not only in browser filters.
- Allow a person to belong to more than one school with a distinct role at each school.
- Keep teacher attendance access limited to active class/section assignments within the selected school.
- Preserve the existing APS staff/admin login while introducing explicit school membership for new tenants.
- Keep school onboarding and membership grants restricted to a trusted provisioning path.

## Proposed authorization model
Add a `public.school_memberships` relation with:
- `id uuid primary key`
- `school_code text not null`
- `user_id uuid not null references auth.users(id)`
- `role text not null check (role in ('SCHOOL_ADMIN','TEACHER'))`
- `active boolean not null default true`
- `created_at timestamptz not null default now()`
- unique membership per `(school_code, user_id)`

Memberships are provisioned by a trusted server-side/admin process using a service-role credential that must never be exposed to the browser. Authenticated clients should initially receive SELECT access only to their own membership rows. Do not allow users to insert or update their own role/membership through ordinary client requests.

## RLS policy direction
- School admins may manage student roster, class assignments, and attendance only when an active `SCHOOL_ADMIN` membership exists for that same `school_code`.
- Teachers may read roster/attendance only when an active membership and matching active class/section assignment exist for the same school.
- Teacher attendance INSERT/UPDATE must bind `marked_by = auth.uid()` and validate the student's school and active assignment in both `USING` and `WITH CHECK` as applicable.
- Assignment creation/deactivation is admin-only for that school.
- Membership reads are self-only; membership grants/revocations are service/provisioning-only until a separately reviewed delegated-admin workflow exists.
- Keep the existing `private.is_admin()` APS compatibility path limited to `ashiana` during migration. It must not grant access to any other school.
- Avoid relying on user-editable `user_metadata` for roles or tenant authorization.

## Application changes required before multi-school launch
1. Introduce a validated school context after authentication; do not accept an arbitrary school code from an untrusted browser parameter as authorization.
2. Load the user's active memberships and present a school selector only when the user belongs to multiple schools.
3. Pass the selected, membership-backed school context to student roster, assignment, and attendance queries instead of the hard-coded `APS_STUDENT_SCHOOL`.
4. Ensure admin pages derive their capabilities from the selected school's role, not the global `currentAuthUser.type` alone.
5. Keep staff attendance behavior unchanged while student attendance transitions to the membership-backed context.
6. Provide a trusted onboarding path to create a school and its first `SCHOOL_ADMIN` membership.

## Required validation before merge/deploy
- Anonymous users cannot read any membership or student records.
- A user with no membership cannot read or mutate a school's student data.
- School A admin cannot read or mutate School B data, including by changing API filters or request payloads.
- School A teacher can access only explicitly assigned class/sections in School A.
- Deactivated memberships and assignments immediately block access on subsequent requests.
- Teacher cannot spoof `marked_by`, change `school_code`, or attach attendance to a student in another school.
- Existing APS admin and teacher workflows continue to work.
- Validate INSERT, SELECT, UPDATE, DELETE, and upsert behavior with authenticated test users against an isolated Supabase test project; run Supabase security/performance advisors after schema changes.

## Rollout sequence
1. Restore access to the isolated Supabase test project and confirm schema/migration workflow.
2. Implement the membership schema and RLS changes as a new migration, without editing the already merged student-attendance migration.
3. Add test fixtures for at least two schools, two admins, and teachers with overlapping class names.
4. Implement the application school-context resolver and membership-aware role checks.
5. Run policy and end-to-end tests in isolation; fix findings and repeat.
6. Review compatibility and only then prepare a separate production migration/deployment plan.

## Current blocker
The earlier isolated test database connection returned a permissions error, and the student-attendance tables are not present in production. Therefore no membership migration should be applied to production or treated as runtime-verified until isolated database access and RLS tests are available.
