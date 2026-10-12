-- Roll back the student ID-card issuance-status RPC introduced in PR #126.
-- The frontend is restored to the pre-issuance-gate student ID-card flow.
drop function if exists public.student_id_card_issued(text, text, text);
