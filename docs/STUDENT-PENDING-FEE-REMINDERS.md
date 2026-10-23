# Student Pending Fee Reminders

## Behaviour
- Runs daily at 06:00 India Standard Time through GitHub Actions.
- Reminder stages: 3 days before due date, on the due date, and once when an installment is at least 7 days overdue.
- Uses configured fee installments and the outstanding amount from the production fee ledger.
- Allocates approved account-level discounts to installments oldest-first.
- Suppresses reminders for an installment while a payment is awaiting Admin or Principal review.
- Skips zero-balance installments and de-duplicates each stage by installment and due date.
- Saves an in-app reminder in `fee_student_reminders` and sends Android FCM / web push where a student device is registered.
- Student portal reads reminders through the existing admission-number/DOB student session token; the table itself is not directly readable by anon/authenticated roles.

## Required secrets before enabling scheduled delivery
Create one strong random secret and store the *same value* in both places. Do not commit the value to the repository.

1. Supabase Dashboard → Ashiana-Attendance-DB → Edge Functions → Secrets: add `FEE_REMINDER_CRON_SECRET`.
2. GitHub repository → Settings → Secrets and variables → Actions → New repository secret: add `FEE_REMINDER_CRON_SECRET`.
3. Deploy the `fee-reminders` Edge Function with JWT verification disabled as declared in `supabase/config.toml`. It authenticates every request with the dedicated `x-fee-reminder-secret` header.
4. Apply migration `20261023190000_student_pending_fee_reminders.sql` to the live Ashiana-Attendance-DB project.
5. Deploy the updated `fee-management` Edge Function so the student portal can read the reminder inbox.
6. Merge the feature PR only after validation passes. The scheduled workflow runs at 06:00 IST and can also be invoked manually.

## Operational notes
- A reminder is only delivered on the stage date; the overdue stage is sent once on the first daily run at least 7 days after due date.
- Push delivery requires existing student device subscriptions and the existing VAPID / FCM secrets.
- GitHub Actions success confirms the endpoint responded; review the JSON counters and Supabase Edge Function logs for actual delivery results.
- No payment records, receipts, fee structures, or student data are created or changed by the reminder scheduler. It creates only reminder records and delivery-attempt logs.
