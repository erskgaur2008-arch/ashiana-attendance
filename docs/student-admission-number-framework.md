# Student admission-number framework

## Format and source of the serial

The database stores:
- `registration_year`: full year (for example, `2026`)
- `serial_number`: numeric value of the existing `student_roster.enroll_no`
- `admission_number`: formatted value, for example `APS-26-0142`

The existing Enroll No is the source of NNNN. The migration does **not** alphabetically renumber students, rewrite Enroll No, or change student UUIDs. Numeric Enroll Nos must be 1–9999. If values such as `0012` and `12` coexist, bulk generation stops and reports a duplicate numeric serial rather than assigning ambiguous IDs.

## Apply and run

1. Review and apply `supabase/migrations/20261027000100_student_admission_number_framework.sql` to the intended Supabase project. This migration has not been run against production by this change.
2. Confirm that all Enroll Nos for the batch are numeric and unique by numeric value.
3. Sign in as an authorized administrator, then call the RPC from the authenticated Supabase client:

```js
const { data, error } = await supabaseClient.rpc(
  'admin_generate_student_admission_numbers',
  {
    p_school_code: 'ashiana',
    p_registration_year: 2026
  }
);
if (error) throw error;
if (!data?.success) throw new Error('Admission number generation did not complete.');
console.info('Admission numbers generated:', data.generated_count);
```

The function processes all students for the specified school who have no `admission_number`. It runs in one database transaction, takes a transaction-scoped advisory lock, validates the full batch before writing, and relies on unique indexes as the final concurrency guard. A failed validation rolls the entire call back.

## Mid-term additions

New student records with a numeric Enroll No and an explicit `registration_year` get their formatted number from the trigger. If the year is omitted on insert, the trigger uses the current calendar year; pass the actual admission year for backdated admissions. The trigger uses the existing Enroll No as the serial, so existing student numbers are never re-sorted or changed. If a student has a non-numeric Enroll No, the framework deliberately leaves the formatted number unset rather than inventing a conflicting number; correct the Enroll No before generating.

## Verification queries

```sql
-- Verify format and check missing numbers.
select id, enroll_no, registration_year, serial_number, admission_number
from public.student_roster
where school_code = 'ashiana'
order by registration_year, serial_number nulls last, student_name;

-- Must return no rows: duplicate formatted numbers.
select admission_number, count(*)
from public.student_roster
where admission_number is not null
group by admission_number
having count(*) > 1;

-- Find records that cannot be formatted from the existing Enroll No.
select id, enroll_no, student_name
from public.student_roster
where school_code = 'ashiana'
  and admission_number is null
  and coalesce(trim(enroll_no), '') !~ '^[0-9]{1,4}$';
```

## Scope note

This repository uses Supabase/Postgres and a static browser frontend, not a Node.js/Express/MySQL or PHP/PDO backend. The migration therefore implements the framework in the application's actual database stack. The current change provides the schema, protected bulk RPC, uniqueness/indexing, and automatic generation trigger. Frontend labels and ID-card displays should only be wired to `admission_number` after this migration is applied and verified in a test project.
