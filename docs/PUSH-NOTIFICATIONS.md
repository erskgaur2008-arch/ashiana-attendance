# Push notifications — implementation and rollout notes

## Current implementation

- Website/PWA notifications use Web Push through the existing `push-notifications` Edge Function.
- Android notifications use Firebase Cloud Messaging (FCM) HTTP v1 from the same Edge Function.
- The student portal uses RPC login (`student_login`) instead of Supabase Auth. Student device registration validates the submitted admission number and DOB password through that existing RPC before saving a device subscription.
- Admin notice publishing invokes the Edge Function after the notice row is saved. A push delivery failure does not roll back or delete the published notice.
- Student device subscriptions are stored separately in `student_push_subscriptions`, with RLS enabled and no direct grants to browser/mobile roles. The Edge Function writes and reads these rows using the service role.

## Student attendance notifications (PR under review)

- The teacher attendance-save flow and the student QR attendance flow request a targeted notification only after the database confirms a successful save. The manual save path compares existing statuses first, so saving unchanged values does not create repeated alerts.
- The existing `push-notifications` Edge Function validates the active admin/staff caller and checks the saved attendance row before creating an in-app notification and sending Web Push/FCM to subscriptions matching that student's admission number.
- The additive `20261022_student_attendance_notifications.sql` migration creates a private notification table and extends `student_portal_bundle_by_session` to return only the signed-in student's notification history. The Student Portal displays the most recent notifications in its dashboard.
- Notification delivery is best-effort: a push failure must not undo attendance that has already been saved. Duplicate notifications for the same student/date/status are suppressed.
- This feature is not active until the migration and updated Edge Function are reviewed, tested, and separately deployed to the intended Supabase project. This PR does not apply migrations, deploy functions, merge, or build an APK.

## Attendance notification verification

1. Apply the migration to an isolated test project first and deploy the updated Edge Function there.
2. Register a student Android device and/or grant Web Push permission from that student's portal.
3. Mark a student Present by QR; verify the matching student sees an in-app notification and receives a phone/browser push when delivery is configured.
4. Mark or change attendance through the Class Teacher's Save Attendance flow; verify only changed records create notifications.
5. Save the same statuses again; verify duplicate alerts are suppressed.
6. Verify a different student's device receives nothing, unauthorized staff cannot send notifications, and a failed push does not roll back the saved attendance.
7. Re-test Student/Admin/Teacher login, refresh/session restore, QR attendance, attendance reports, ID cards, notices, and existing push notifications.

## Required configuration before real delivery

1. Apply `supabase/migrations/20261015_student_push_subscriptions.sql` to the intended Supabase project only after review. It creates a new table and indexes; it does not modify existing student records.
2. In Supabase Edge Function secrets, set `FCM_SERVICE_ACCOUNT_JSON` to the complete Firebase service-account JSON for the Android app's Firebase project. Enable the Firebase Cloud Messaging API for that project. Never commit that JSON or its private key to GitHub.
3. Ensure `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, and `VAPID_SUBJECT` are set for Web Push.
4. For Android APK builds, add a GitHub Actions repository secret named `GOOGLE_SERVICES_JSON` containing the complete `google-services.json` for the Firebase Android app whose package ID matches the generated APK. The workflow installs this file only during the build and applies the Google Services Gradle plugin; the JSON is not committed. Without this secret, APK builds continue but Android token registration will not work.
5. Deploy the updated Edge Function only after the migration and secrets are configured in a test Supabase project. This PR does not deploy anything.

## Verification checklist

- Sign in to the student portal and grant notification permission. Check that `student-subscribe` succeeds without creating a Supabase Auth session for the student.
- Check that the student device row is created for the expected admission number, class and section.
- Publish a notice from Admin Student Portal Management for all classes and for one class/section. Confirm the notice remains visible in the student portal and the Edge Function reports delivery counts.
- Test Android background notifications and Web/PWA notifications separately.
- Test teacher, staff, admin and student login, refresh, logout, QR attendance, ID-card generation and existing notice management.

## Safety

- No production database migration, Edge Function deployment, secret update, merge or APK build is performed by this change.
- The existing `push_subscriptions` table and its authenticated-user subscription path are preserved.
- The new student subscription table is separate and access is restricted to the Edge Function service role.
