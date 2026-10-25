# Ashiana Attendance

Web attendance and school-management application for Ashiana Public School, with role-based Admin, Staff/Teacher, and Student portals. The web app is hosted through GitHub Pages; Supabase provides authentication, database, storage, and Edge Functions. The Android wrapper uses Capacitor.

## Main components

- `index.html` — current web application entry point.
- `sw.js` — offline app-shell and static-asset service worker, plus Web Push notification handling.
- `manifest*.webmanifest` — installable PWA manifests for the general, admin, staff, and student experiences.
- `supabase/migrations/` — versioned database schema, policies, and RPC changes.
- `supabase/functions/` — server-side Edge Functions.
- `mobile/` and `capacitor.config.ts` — mobile wrapper and configuration.
- `.github/workflows/` — validation and Android build workflows.

## Development and safety

1. Work in a feature branch and open a pull request; do not commit directly to `main`.
2. Review the exact migration SQL before applying it to the production Supabase project.
3. Never commit Supabase service-role/secret keys, private push credentials, signing keys, or other secrets. Keep server-only values in Supabase Edge Function secrets or GitHub Actions secrets.
4. The Supabase anon/publishable key may be used by the browser only when database access is correctly protected by Row Level Security (RLS) and server-side authorization.
5. Do not log PINs, passwords, session tokens, private student details, or secret values.
6. Test changes against existing login flows, attendance, leave, fees, notifications, and offline behavior before merging or deploying.
7. Never disable RLS as a workaround. A table with RLS enabled and no policies is inaccessible through ordinary client queries unless access is provided through a carefully authorized server-side function.

## Local checks

The repository currently has no frontend build step. Inspect the changed JavaScript and SQL, run available GitHub Actions validation workflows, and test in a non-production environment where possible. Android builds are configured in `package.json` and GitHub Actions.

## Production deployment

GitHub Pages publishes the configured branch/source. Supabase database migrations and Edge Function deployments are separate operations; changing a file in this repository does not automatically apply a database migration or deploy an Edge Function unless a workflow explicitly does so. Confirm each target and the workflow result before treating a change as live.
