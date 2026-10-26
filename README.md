# Ashiana Attendance

A school attendance and administration Progressive Web App (PWA) for **Ashiana Public School**, with student, teacher, staff, and administrator workflows. The application runs as a web app and through an Android wrapper built with Capacitor.

> **Status note:** This README documents the application and requirements discussed during development. It is not a security certification or a guarantee that every feature is currently enabled in production. Confirm current code, GitHub Actions runs, Supabase configuration, and pull-request status before releasing changes.

## Contents

- [Overview](#overview)
- [Technology stack](#technology-stack)
- [Architecture](#architecture)
- [Roles and access](#roles-and-access)
- [Features](#features)
- [Security and privacy](#security-and-privacy)
- [Development and deployment](#development-and-deployment)
- [Testing and release checklist](#testing-and-release-checklist)
- [Current audit notes](#current-audit-notes)

## Overview

Ashiana Attendance brings school attendance and related student/staff services into one application. The frontend is a static, single-page HTML application backed by Supabase. It is also packaged for Android using Capacitor.

The project is developed incrementally. Preserve existing production data and working features; review and test changes rather than replacing the application or rebuilding it from scratch.

## Technology stack

- **Frontend:** HTML, CSS, and JavaScript, with `index.html` as the main entry point.
- **PWA:** Web app manifests and a service worker for installability, caching, and supported Web Push behavior.
- **Backend:** Supabase Authentication, PostgreSQL, Row Level Security (RLS), Storage, RPCs, and Edge Functions where configured.
- **Android:** Capacitor wrapper and Android build workflow.
- **Source control and CI:** GitHub repository and GitHub Actions.
- **Notifications:** Firebase Cloud Messaging (FCM) for Android and Web Push/VAPID for supported browser/PWA notifications, where configured.

Confirm exact versions, environment variables, enabled services, and deployment workflows from the current repository and project settings.

## Architecture

```text
Browser / installed PWA / Android Capacitor app
                      |
                      v
           Static frontend (index.html)
              |                 |
              v                 v
       Supabase Auth       PWA service worker
              |
              v
       Supabase database and APIs
        |          |          |
        v          v          v
       RLS        RPCs    Edge Functions
                              |
                              v
                       Push providers
                      (when configured)
```

The web app is hosted through GitHub Pages. The Android application packages the web app through Capacitor. Backend authorization depends on Supabase policies, database grants, and server-side function checks.

**A frontend role selector or hidden UI element is not an authorization boundary.** Sensitive operations must be authorized by the backend.

## Roles and access

| Role | Main responsibilities |
|---|---|
| **Administrator** | Manage school data, students, staff, teacher assignments, notices, attendance administration, fee structures, and supported configuration. |
| **Teacher** | Access assigned classes/sections and teacher tools. Class teachers can mark attendance for assigned students; subject teachers have view access where configured. |
| **Staff** | Access staff-specific services, including staff attendance and supported workflows. |
| **Student** | Sign in to the student portal and view their own school information and services. |

Exact permissions must be determined from the current application code and Supabase policies. Do not assume every role has every capability in every deployment.

### Authentication and sessions

The project has undergone fixes and validation for session persistence, including student session behavior after closing and reopening the Android app. Verify the current implementation before changing login flows.

Regression coverage should include:
- Sign-in and sign-out for every role.
- Refresh/reload and close/reopen behavior.
- Session expiry and reauthentication.
- Direct access to restricted pages and API operations.
- Switching roles/accounts without retaining another user's data.
- Confirming users can only access authorized records.

## Features

### Attendance
- QR-code-based student attendance workflow.
- Validation against a student's admission/enrollment identifier.
- Class/section and teacher assignment workflows.
- Attendance date handling, including defaulting the teacher attendance date to today.
- Staff attendance workflows, including geofence validation where enabled.

QR codes identify records; they must not be the only authorization mechanism. The backend must verify permissions and the attendance operation.

### Student records and bulk upload

Student fields discussed for the application include admission number, roll number, name, class, section, gender, category, status, date of birth, parent/guardian names, address, phone number, and photo.

Bulk student import is intended to support CSV files, including large imports (up to approximately 2,000 rows in the discussed requirements). Import workflows should validate headers and data types, identify duplicates, preview changes, and require confirmation before writing records.

Never commit real student data, credentials, PINs, or secrets in sample CSV files.

### Staff management

Staff workflows include employee records, staff attendance, and secure PIN assignment/reset. Import workflows should map columns explicitly, validate required fields and duplicates, preview changes, and require confirmation before importing.

**Do not import, export, log, or store staff PINs in CSV files or source control.**

### Student portal
Dashboard requirements include:
- Notices and school announcements.
- Attendance.
- Homework and timetable.
- Leave request form and leave status.
- Report card and school calendar.
- Student photo and ID-card information, where enabled.

### Teacher and administrator tools
Workflows discussed include:
- Assigning teachers to classes/sections.
- Assigning class teachers and subject teachers.
- Managing student and staff records.
- Managing notices and school information.
- Reviewing attendance and student services.
- Managing student/staff ID-card previews and QR codes.

### ID cards
Student and staff ID-card workflows have included QR codes, photos, school details, card layout adjustments, and a student-card back that can show the QR code. The requested footer is:

> This ID card is the property of Ashiana Public School. If found, please return it to the school office.

Check the live UI for the exact current fields and layout.

### Leave management
- Student leave requests.
- Leave status display.
- Review workflows where configured.
- Push notifications for leave-status updates where configured.

### Fees management
Fees management work has included:
- Creating fee structures and assigning them to multiple classes.
- Fee categories/installments: **Admission Charges, Quarter 1, Quarter 2, Quarter 3, and Quarter 4**.
- Student-facing fee visibility.
- Payment instructions using an administrator-provided UPI address or QR code.
- Fee reminders through a backend function where configured.

Fee records and payment status must be validated server-side. A displayed UPI QR code or payment instruction is not proof that a payment was received. Verify payment reconciliation and end-to-end behavior before marking payments confirmed.

### Push notifications

Notification types discussed include school notices, leave-status changes, homework/timetable updates, attendance updates, and pending-fee reminders where configured.

Prior tests in a test environment reported successful notification delivery, correct app opening when tapped, matching the expected notice, and no duplicate in the tested scenario. Those results apply only to the tested build/environment and do not prove every production notification path works.

Delivery depends on Firebase configuration, Android app configuration, VAPID settings for web push, backend secrets, token registration, and user permission settings. Never commit service-account JSON files or private push keys.

## Security and privacy

This application handles school records, including information about minors. Treat student, parent, staff, attendance, fee, and authentication data as confidential.

### Security principles
- **Least privilege:** Grant each role only the access needed for its work.
- **Backend authorization:** Enforce permissions in RLS policies, database grants, RPCs, and Edge Functions—not only in the frontend.
- **RLS:** Review policies for every table containing private school data. Test both allowed and denied access for every role.
- **Input validation:** Validate and normalize values at server boundaries.
- **Safe rendering:** Escape untrusted values and avoid inserting untrusted strings into HTML or executable inline handlers. Prefer safe DOM APIs and event listeners.
- **Authentication:** Test login, logout, session persistence, expiry, and account/role isolation.
- **Secrets:** Keep service-role keys, database credentials, signing keys, FCM service-account data, and VAPID private keys in approved secret storage. Never place them in frontend code or Git history.
- **PIN protection:** Never log or export PINs. Enforce server-side verification, rate limiting, and secure reset procedures.
- **Uploads:** Validate file type, size, ownership, and storage access.
- **Auditability:** Review privileged actions and security failures without logging passwords, PINs, access tokens, or unnecessary personal information.
- **Data minimization:** Use synthetic data for development and screenshots wherever possible.

### Production safety
- Do not run destructive SQL against production without a reviewed migration and an explicitly authorized plan.
- Do not disable RLS to make a feature work.
- Do not expose service-role credentials to the browser.
- Do not merge an unverified security fix solely because one CI job passed.
- Keep test data and production data clearly separated.
- Confirm the target Supabase project and deployment target before running migrations, deploying Edge Functions, or releasing an APK.

## Development and deployment

### Repository and live application
- **Source repository:** [erskgaur2008-arch/ashiana-attendance](https://github.com/erskgaur2008-arch/ashiana-attendance)
- **Live PWA:** [Ashiana Attendance on GitHub Pages](https://erskgaur2008-arch.github.io/ashiana-attendance/)

### Local development

The application is primarily a static frontend. A typical inspection workflow is:

1. Clone the repository.
2. Review the current README, workflow files, package manifests, and deployment configuration.
3. Serve the application locally if browser APIs or the service worker do not work from a `file://` URL.
4. Use approved development/test Supabase credentials and synthetic data.
5. Test each role and the relevant backend policies.
6. Run the repository's documented checks before submitting changes.

```bash
git clone https://github.com/erskgaur2008-arch/ashiana-attendance.git
cd ashiana-attendance
```

Use commands documented in the current repository for building, testing, and deploying. Do not assume a package manager or build command is available without checking the repository.

### GitHub Actions and Android APKs

GitHub Actions is used for CI checks and Android APK builds. Before distributing an APK:

1. Confirm the intended Supabase backend and app configuration.
2. Confirm required workflows have completed successfully.
3. Review the commits included in the build.
4. Install and test the APK on a device.
5. Test login/session persistence, attendance, leave management, notifications, and affected features.
6. Verify that development/test backend settings are not included in a production build.

Do not publish an APK built against a test Supabase project as a production app.

### Supabase operations

Before changing the database or deploying an Edge Function:

1. Verify the target Supabase project.
2. Review the migration/function diff.
3. Check required environment variables and secrets without exposing their values.
4. Confirm RLS policies and database grants.
5. Run relevant tests.
6. Verify logs and behavior after deployment.

Changing a repository file does not automatically apply a database migration or deploy an Edge Function unless a workflow explicitly does so.

## Testing and release checklist

### CI and code review
- [ ] All required GitHub Actions checks have completed.
- [ ] No required workflow is pending or failed.
- [ ] Changes have been reviewed for correctness and side effects.
- [ ] Merge conflicts are resolved without dropping security checks or existing functionality.
- [ ] No secrets or private records were added to the repository.

### Security
- [ ] Dynamic HTML and inline event-handler changes have been reviewed.
- [ ] RLS policies, grants, RPCs, and Edge Functions enforce authorization.
- [ ] Each role has been tested for allowed and denied operations.
- [ ] PIN verification/reset paths are protected against abuse.
- [ ] Session and account isolation are tested.
- [ ] Service-worker caching does not expose private data across users.
- [ ] Uploads and private assets have appropriate access controls.

### Regression
- [ ] Administrator sign-in, dashboard, and management actions work.
- [ ] Teacher sign-in and assigned-class permissions work.
- [ ] Staff sign-in and staff attendance work.
- [ ] Student sign-in and portal work.
- [ ] Refresh, close/reopen, logout/login, and session expiry behave correctly.
- [ ] QR scanning and attendance recording work.
- [ ] Student/staff records and ID cards render correctly.
- [ ] Leave requests and status updates work.
- [ ] Fees display for the intended students/classes.
- [ ] Payment instructions and payment status are accurate.
- [ ] Push notifications arrive and open the correct screen.
- [ ] Mobile layout and PWA installation still work.

### Release
- [ ] Correct production backend and secrets are configured.
- [ ] Database migrations and function changes have been reviewed.
- [ ] Production changes are explicitly authorized.
- [ ] The release is tested on the deployed web app and intended Android build.
- [ ] Final PR and deployment status are recorded.

## Current audit notes

The latest status shared during development showed these CI validations as **PASS**:
- HTML injection boundary validation.
- Student browser session validation.
- Service worker security validation.
- Security secret scan.
- Staff geofence validation.
- Fee reminder function validation.

At that check, **Fees Management draft validation was still running**. Additional inline-handler and dynamic-HTML insertion points had been scanned, but remaining authorization paths and rendering cases still required review.

A passing workflow is evidence only for the checks it actually runs; it is not proof that the entire application is secure.

The latest status screenshot referenced commit `696d24285f2fba14c69ea2f91b2a7f8a1a78ae58`. PR **#274 was not confirmed merged** in that status. Check GitHub for the current PR state, latest commit, and workflow results before merging or deploying. Complete the remaining authorization/rendering review and regression tests first.

This README consolidates requirements and status reported during development; it is not a live inspection of the repository. Verify current feature availability, CI results, PR status, backend configuration, and deployed functions before making release decisions.

---

Maintained for Ashiana Public School. Keep this document aligned with current code, workflows, backend configuration, and verified production behavior.
