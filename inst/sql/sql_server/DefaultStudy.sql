-- First recorded site-local use; CohortMethod applies first-use, age and OP filters.
SELECT DISTINCT person_id AS subject_id,
       CASE WHEN arm = 1 THEN 1 ELSE 2 END AS cohort_definition_id,
       index_date AS cohort_start_date,
       CASE WHEN end_date >= index_date THEN end_date ELSE index_date END AS cohort_end_date,
       index_date AS covariate_cutoff
INTO #fps_exposure
FROM #fps_drug WHERE arm >= 0;
