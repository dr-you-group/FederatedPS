-- Smoke-test subset, not a representative research sample. Preserve ALL
-- exposure rows for each selected patient so CohortMethod retains its normal
-- first-use, crossover, age, washout and observation-period rules.
-- Only session-local temporary tables are changed.
;WITH first_exposure AS (
    SELECT subject_id, cohort_definition_id,
           ROW_NUMBER() OVER (PARTITION BY subject_id
               ORDER BY cohort_start_date, cohort_definition_id) AS exposure_rank
    FROM #fps_exposure
), arm_order AS (
    SELECT subject_id, cohort_definition_id,
           ROW_NUMBER() OVER (PARTITION BY cohort_definition_id ORDER BY subject_id) AS arm_rank
    FROM first_exposure WHERE exposure_rank = 1
)
SELECT TOP (@patient_limit) subject_id INTO #fps_limited_person
FROM arm_order
ORDER BY arm_rank, cohort_definition_id, subject_id;
CREATE UNIQUE CLUSTERED INDEX ix_fps_limited_person ON #fps_limited_person(subject_id);
DELETE e FROM #fps_exposure e
WHERE NOT EXISTS (SELECT 1 FROM #fps_limited_person p WHERE p.subject_id = e.subject_id);
