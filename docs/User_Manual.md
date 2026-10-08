# Ashiana Public School — Attendance & Student Portal User Manual

**Version 1.0 • October 2026**  
**For Students • Teachers / Staff • Administrators**

## 1. About the Application
This application is a cloud-synchronised school attendance and student portal for Ashiana Public School, Sector 46-A, Chandigarh. It provides separate role-based experiences for Students, Teachers/Staff, and Administrators.

Main areas include staff QR attendance, teacher student attendance, student portal services, faculty leave management, student/class management, reports, corrections, ID cards, and cloud synchronisation.

## 2. Access & Login
### Students
1. Select **Student** on the login screen.
2. Enter **Admission No.**
3. Enter **Date of Birth** as the password in **DDMMYYYY** format.
4. Tap **Login to Student Portal**.

### Teachers / Staff
1. Select **Teacher/Staff**.
2. Enter **Employee ID or official email**.
3. Enter the personal **4-digit Attendance PIN**.
4. Sign out when finished on a shared device.

### Administrators
1. Select **Administrator**.
2. Enter the authorised administrator email and password.
3. Use **Forgot Administrator Password?** if a reset is required.

> Camera attendance requires HTTPS and camera permission.

## 3. Student User Manual
After login, the Student Portal provides:

- **Profile** — View student details, parents, phone and address.
- **Notice** — Read notices published for the student's class.
- **Attendance** — View attendance records and Present/Absent/Leave counts.
- **Homework** — View subject-wise homework, descriptions and due dates.
- **Timetable** — View periods, subjects, teachers and rooms when published.
- **Leave Request** — Enter from/to dates, reason and DOB password; submit and track requests.
- **Report Card** — View published academic-year/term results, subject grades/marks, overall grade and remarks.
- **School Calendar** — View published events and dates.
- **ID Card** — Open the digital student ID card and print it from the preview.

## 4. Teacher / Staff User Manual
The staff side menu contains **Punch, Students (teachers only), History, Leave, Profile, and Sign Out**.

### A. Staff Attendance
1. Tap **MARK ATTENDANCE**.
2. Allow camera access.
3. Scan the school's current **Daily QR**.
4. Enter your personal **4-digit PIN**.
5. Tap **Verify PIN & Mark Attendance**.
6. The system records the next **PUNCH IN** or **PUNCH OUT**.

Today's dashboard shows first IN, last OUT, work time, break time, late/early minutes and punch history.

**Current configured shift:** 07:40 AM–02:30 PM.  
**Current displayed late threshold:** after 07:50 AM.

### B. Staff ID Card
Open the staff ID preview from the profile/avatar area. If the ID card is expired, attendance punching is blocked until the administrator renews the Valid Thru date.

### C. Attendance History
Open **History**, select a month and status filter, and review attendance by date. Summary metrics include days present, total hours, late days and leaves.

### D. Leave
Open **Leave** or the dashboard leave section to submit and review leave requests.

### E. Teacher Student Attendance
Teaching staff can open **Students** to:
- Select an assigned class and date.
- View assigned students.
- Save attendance.
- View attendance records.
- Scan student ID cards using **Scan QR**.

For student QR attendance, the system validates the student's identity and the teacher's class assignment before marking attendance. A student outside the teacher's assigned class cannot be marked by that teacher.

### F. Student Portal Management
Teachers can manage content for their assigned classes:
- Notice
- Homework
- Timetable
- Calendar Event
- Report Card

Teachers can also review student leave requests available to their assigned classes.

## 5. Administrator User Manual
The Administrator dashboard provides faculty attendance monitoring plus student and staff management.

### A. Dashboard
KPIs include:
- Total Faculty
- Present Today
- Working Now
- Late Today
- On Leave
- Total Work

### B. Live Attendance
Open **Live Attendance** to review the faculty roster, search staff and export the live roster to CSV.

### C. Daily QR
Open **Daily QR** and display today's school QR at the attendance station. Teachers scan this QR before entering their personal PIN. The QR is date-specific.

### D. Faculty Directory
The **Faculty** area supports:
- Search faculty
- Add staff
- Import staff from Excel
- Export PIN-status CSV
- Generate bulk staff ID cards on A4
- Manage staff records

### E. Student & Class Management
The **Students** area supports:
- Search/filter students by name, enrollment number, class, section and status.
- Add students.
- Bulk upload students.
- Edit student profiles and photos.
- Create student ID cards.
- Assign class teachers.
- Assign subject teachers.
- Delete selected records where authorised.

### F. Student Attendance
In **Students**, click **View Attendance** to open the attendance panel. Filter by date/class/section and review attendance. The **Marked By** column identifies the teacher who marked the attendance.

### G. Student Attendance Report
Use the **Attendance Report** quick action to generate class-wise attendance summaries for a selected date and print the report.

### H. Reports & Muster Roll
Open **Reports** and choose:
- Daily Report
- Monthly Summary
- Faculty Individual

Filters include date/month, faculty, department, attendance status and quick search.

Available outputs:
- Excel (.xlsx)
- CSV
- Print / PDF

### I. Faculty Leave Applications
Open **Leaves** to review faculty leave applications including faculty, type, dates, reason, status and available actions.

### J. Manual Corrections
Open **Corrections**:
1. Select the faculty member.
2. Choose **Force PUNCH IN** or **Force PUNCH OUT**.
3. Enter the timestamp.
4. Enter an administrative audit reason.
5. Save the correction.

Use corrections only when authorised. The action is recorded for audit purposes.

### K. Audit / Cloud Sync
The audit/cloud area provides audit records and synchronisation controls. **Force Sync Now** can be used when a manual refresh is required.

## 6. Recommended Daily Workflow
1. **Morning admin:** Open Daily QR and display today's QR at the attendance station.
2. **Teacher arrival:** MARK ATTENDANCE → scan Daily QR → enter PIN → PUNCH IN.
3. **Teacher departure:** Repeat the process for PUNCH OUT.
4. **Class attendance:** Teachers open Students → select assigned class/date → save attendance or scan student QR.
5. **Admin review:** Use Live Attendance for current faculty status and Reports for formal records.
6. **Leave processing:** Review faculty and student leave requests according to school policy.
7. **End of day:** Verify unusual attendance, apply authorised corrections with a reason, and export/print reports when required.

## 7. Security & Good Practice
- Never share a staff Attendance PIN or administrator password.
- Students should not share Admission No. and DOB password.
- Only authorised teaching staff should use student attendance functions.
- Do not unnecessarily share Daily QR codes.
- Use device security and sign out from shared computers.
- Use Manual Corrections only when authorised and always provide a clear reason.
- Store exported CSV/Excel reports in an authorised school location.

## 8. Troubleshooting
**Camera does not open:** Confirm HTTPS, allow camera permission, close other camera apps and retry.

**Daily QR rejected:** Ask the administrator to display/load today's QR. Do not use an old QR.

**Incorrect PIN:** Re-enter the 4-digit PIN. Repeated failed attempts may trigger temporary rate limiting.

**ID card expired:** Contact the administrator to renew the staff Valid Thru date.

**Teacher cannot mark a student:** Confirm the student belongs to the teacher's assigned class/section and the correct teacher account is being used.

**Student portal shows no content:** Content may not yet be published for that student/class. Refresh and try again.

**Admin report is empty:** Check date/month, department, status and search filters, then use Refresh Report.

**Data appears stale:** Use Sync/Force Sync and allow cloud synchronisation to complete.

**Forgot administrator password:** Use Forgot Administrator Password and follow the authorised reset email.

## 9. Quick Reference
| User | Login | Main Functions |
|---|---|---|
| Student | Admission No. + DOB (DDMMYYYY) | Profile, notices, attendance, homework, timetable, leave, report card, calendar, ID card |
| Teacher/Staff | Employee ID/email + 4-digit PIN | Staff attendance, history, leave, profile; teachers also manage assigned student attendance and portal content |
| Administrator | Authorised email + password | Live attendance, Daily QR, faculty, students, reports, leaves, corrections, audit/sync |

## 10. Support / Escalation
For login, account, class assignment, staff PIN, expired ID card, leave approval, report or data issues, contact the school's authorised administrator/system operator.

When reporting a problem, provide the user role, approximate time, screen/function name and exact error message. **Never send passwords or PINs.**


### I. Advanced Attendance Analytics 2.0 — Phase 1
Administrators can open **Analytics 2.0** from the Admin dashboard. The Phase 1 analytics screen provides:
- Custom from/to date range with quick 7/30/90-day ranges.
- Optional class and section filters.
- Configurable low-attendance threshold (default 75%).
- KPI summary for active students, students with attendance, marked records, Present, Absent, and attendance percentage.
- Class/section performance summary.
- Daily attendance trend table.
- Low-attendance student action list (up to 100 students).
- Read-only analytics; existing attendance marking and permissions are not changed.


### J. Advanced Attendance Analytics 2.0 — Phase 2
Phase 2 adds student-level intervention tools:
- Student attendance ranking, lowest attendance first.
- Student-level Present / Absent / Leave totals and attendance percentage.
- Chronic absence list for students with 3 or more absent records.
- CSV export of the student attendance analytics list.
- Class and section filters from Phase 1 continue to apply.
- All analytics remain read-only and admin-only.



### K. Advanced Attendance Analytics 2.0 — Phase 3
Phase 3 adds attendance-pattern and early-warning insights:
- Weekday attendance pattern showing Present / Absent / Leave totals and attendance percentage by day of week.
- Consecutive absence risk list for students with 2 or more consecutive absent attendance records.
- Shows the longest absence streak and its start/end dates.
- Existing Phase 1 date, class, section and low-attendance filters continue to apply where relevant.
- Analytics remain read-only and admin-only; no attendance records are modified.
