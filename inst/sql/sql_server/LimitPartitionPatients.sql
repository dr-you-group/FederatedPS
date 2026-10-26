-- DEFAULT scenario only: select exactly the same patients as LimitPatients.sql
-- would after DefaultStudy.sql. First dated target/comparator exposure defines
-- the arm; same-date ties choose target (cohort_definition_id=1). Interleave
-- arms by person_id. Keep all visits/exposures of selected people downstream.
-- studySpecific cannot use this early cap: its eligibility filters run first.
-- fps-step: Apply the existing default patient cap before copying visits
;WITH first_arm AS (
    SELECT p.person_id,
           CASE WHEN c.first_comparator_date IS NULL OR
               (c.first_target_date IS NOT NULL AND c.first_target_date <= c.first_comparator_date)
               THEN 1 ELSE 2 END AS cohort_definition_id
    FROM #fps_person p JOIN #fps_candidate c ON c.person_id = p.person_id
), arm_order AS (
    SELECT person_id, cohort_definition_id,
           ROW_NUMBER() OVER (PARTITION BY cohort_definition_id ORDER BY person_id) AS arm_rank
    FROM first_arm
), selected AS (
    SELECT TOP (@patient_limit) person_id FROM arm_order
    ORDER BY arm_rank, cohort_definition_id, person_id
)
DELETE p FROM #fps_person p
WHERE NOT EXISTS (SELECT 1 FROM selected s WHERE s.person_id = p.person_id);
