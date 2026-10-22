# Student Portal Mentor Display-Name Regression Checks

Run these checks after changing mentor RPCs, staff profiles, or Student Portal rendering.

## Expected behavior
- [ ] Web Student Portal shows the canonical staff name for each assigned teacher.
- [ ] Android/mobile Student Portal shows the same names as the web portal.
- [ ] Class Teacher, Hindi Subject Teacher, and English Subject Teacher roles/subjects remain visible.
- [ ] No email address is ever rendered as the teacher's display name.
- [ ] If the staff profile name is missing, show "Teacher name unavailable" rather than leaking the email into the UI.
- [ ] One teacher assigned to multiple subjects is grouped under the same name with all relevant subject labels.
- [ ] Timetable-only teacher names continue to display.
- [ ] Student session validation and class/section scoping still work.
- [ ] Admin, Teacher, and Student login, dashboard refresh, attendance, and logout remain unaffected.

## Specific regression case
Given a subject-teacher assignment whose email is `charubajaj123@gmail.com` and whose active `public.staff.name` is `CHARU MANCHANDA`, both web and mobile must display `CHARU MANCHANDA` and must not display the email as the title.

## Deployment note
The SQL migration `20261022000300_student_mentor_subject_teacher_display_names.sql` must be applied to the production Supabase database as part of the approved release. Merging the frontend code alone does not update an already-deployed database function.
