-- Explicit binary feature contract; no unfiltered feature query can cross a site.
SELECT c.subject_id, MIN(e.covariate_cutoff) AS covariate_cutoff INTO #fps_cutoff
FROM #cohort_person c JOIN #fps_exposure e ON e.subject_id = c.subject_id
    AND e.cohort_start_date = c.cohort_start_date AND e.cohort_definition_id = c.cohort_definition_id
GROUP BY c.subject_id;
SELECT ingredient_id AS concept_id INTO #fps_excluded FROM #fps_ingredients WHERE arm >= 0
UNION SELECT ca.descendant_concept_id FROM @cdm_database_schema.CONCEPT_ANCESTOR ca
    JOIN #fps_ingredients i ON i.ingredient_id = ca.ancestor_concept_id WHERE i.arm >= 0;

SELECT row_id, covariate_id, covariate_value INTO #fps_covariates FROM (
    SELECT c.row_id, CAST(p.gender_concept_id AS BIGINT) * 1000 + 1 AS covariate_id,
        CAST(1 AS FLOAT) AS covariate_value
    FROM #cohort_person c JOIN @cdm_database_schema.PERSON p ON p.person_id = c.subject_id
    WHERE p.gender_concept_id > 0
    UNION ALL
    SELECT c.row_id, CAST(FLOOR((YEAR(c.cohort_start_date) - p.year_of_birth) / 5.0) AS BIGINT) * 1000 + 2,
        CAST(1 AS FLOAT)
    FROM #cohort_person c JOIN @cdm_database_schema.PERSON p ON p.person_id = c.subject_id
    WHERE p.year_of_birth IS NOT NULL AND p.year_of_birth <= YEAR(c.cohort_start_date)
    UNION ALL
    @clinical_sql
) features;
CREATE UNIQUE CLUSTERED INDEX ix_covariates ON #fps_covariates(row_id, covariate_id);
