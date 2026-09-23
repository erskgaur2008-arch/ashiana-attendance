# EduPunch — GitHub Pages

## Admin: Reset Staff PIN

The Admin Portal now includes a **Reset PIN** action in the Staff Directory.

### How it works
1. Sign in to the Admin Portal using the administrator's Supabase Auth email/password.
2. Open **Faculty & Staff Directory**.
3. Click **Reset PIN** for the staff member.
4. Enter and confirm a new 4-digit PIN.
5. The app calls the protected Supabase `set_staff_pin` database function.
6. The PIN is hashed in Supabase and synchronized with the staff login account.

The app does not display, export, or store the plaintext PIN.

## Deployment

Upload `index.html` and `logo 2.png` to the GitHub Pages repository. The app is a static single-file frontend and does not require a build step.

Supabase Auth must be configured for the deployed GitHub Pages URL. The administrator must also exist as an active row in `public.admin_users` and have a Supabase Auth account.
