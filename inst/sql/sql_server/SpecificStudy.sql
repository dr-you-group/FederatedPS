WITH products AS (
    SELECT DISTINCT arm, ingredient_id, drug_concept_id FROM #fps_drug WHERE arm >= 0
), forms AS (
    SELECT cr.concept_id_1 AS drug_concept_id,
        MAX(CASE WHEN LOWER(c.concept_name) LIKE '%oral%' THEN 1 ELSE 0 END) AS oral,
        MAX(CASE WHEN LOWER(c.concept_name) LIKE '%extended release%' THEN 1 ELSE 0 END) AS extended_release,
        MAX(CASE WHEN LOWER(c.concept_name) LIKE '%injection%' OR LOWER(c.concept_name) LIKE '%injectable%'
                 THEN 1 ELSE 0 END) AS parenteral
    FROM @cdm_database_schema.CONCEPT_RELATIONSHIP cr
    JOIN @cdm_database_schema.CONCEPT c ON c.concept_id = cr.concept_id_2
    WHERE cr.relationship_id = 'RxNorm has dose form' AND cr.invalid_reason IS NULL
      AND EXISTS (SELECT 1 FROM products p WHERE p.drug_concept_id = cr.concept_id_1)
    GROUP BY cr.concept_id_1
), eligible_products AS (
    SELECT p.arm, p.drug_concept_id
    FROM products p JOIN forms f ON f.drug_concept_id = p.drug_concept_id
    WHERE (('@form_policy' = 'parenteral_single' AND f.parenteral = 1)
        OR ('@form_policy' = 'oral_ir_opioid' AND f.oral = 1 AND f.extended_release = 0)
        OR ('@form_policy' = 'oral_single' AND f.oral = 1))
      AND EXISTS (SELECT 1 FROM @cdm_database_schema.DRUG_STRENGTH s
                  WHERE s.drug_concept_id = p.drug_concept_id)
      AND NOT EXISTS (SELECT 1 FROM @cdm_database_schema.DRUG_STRENGTH s
          WHERE s.drug_concept_id = p.drug_concept_id AND s.ingredient_concept_id <> p.ingredient_id
            AND NOT ('@form_policy' = 'oral_ir_opioid' AND s.ingredient_concept_id IN (1125315, 1177480)))
)
SELECT DISTINCT d.person_id, d.index_date, d.visit_occurrence_id, d.arm,
    CASE WHEN e.drug_concept_id IS NULL THEN 0 ELSE 1 END AS eligible
INTO #fps_raw
FROM #fps_drug d
LEFT JOIN eligible_products e ON e.arm = d.arm AND e.drug_concept_id = d.drug_concept_id
WHERE d.arm >= 0 AND d.drug_type_concept_id IN (@record_type_concept_ids);

WITH concurrent AS (
    SELECT person_id, index_date FROM #fps_raw
    GROUP BY person_id, index_date HAVING COUNT(DISTINCT arm) > 1
), starts AS (
    SELECT r.person_id, r.index_date, r.arm,
        MIN(CASE WHEN v.visit_concept_id IN (9201, 9203, 262) AND v.visit_start_date <= r.index_date
            THEN CASE WHEN pv.visit_concept_id IN (9203, 262)
                  AND pv.visit_end_date >= DATEADD(DAY, -1, v.visit_start_date)
                  AND pv.visit_start_date < v.visit_start_date
                THEN pv.visit_start_date ELSE v.visit_start_date END
            ELSE r.index_date END) AS covariate_cutoff
    FROM #fps_raw r
    JOIN #fps_visit v ON v.visit_occurrence_id = r.visit_occurrence_id AND v.person_id = r.person_id
    LEFT JOIN #fps_visit pv ON pv.visit_occurrence_id = v.preceding_visit_occurrence_id AND pv.person_id = v.person_id
    WHERE r.eligible = 1 GROUP BY r.person_id, r.index_date, r.arm
), eligible AS (
    SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.person_id ORDER BY s.index_date, s.arm DESC) AS sequence
    FROM starts s JOIN @cdm_database_schema.PERSON p ON p.person_id = s.person_id
    WHERE s.index_date >= DATEADD(YEAR, @min_age,
        DATEFROMPARTS(p.year_of_birth, COALESCE(p.month_of_birth, 1), COALESCE(p.day_of_birth, 1)))
      AND EXISTS (SELECT 1 FROM @cdm_database_schema.OBSERVATION_PERIOD o
        WHERE o.person_id = s.person_id
          AND s.index_date BETWEEN DATEADD(DAY, @prior_days, o.observation_period_start_date) AND o.observation_period_end_date)
      AND EXISTS (SELECT 1 FROM @cdm_database_schema.CONDITION_OCCURRENCE c
        JOIN #fps_visit v ON v.visit_occurrence_id = c.visit_occurrence_id AND v.person_id = c.person_id
        JOIN @cdm_database_schema.CONCEPT concept ON concept.concept_id = c.condition_concept_id
        WHERE c.person_id = s.person_id AND concept.domain_id = 'Condition' AND concept.standard_concept = 'S'
          AND (c.condition_concept_id IN (@indication_concept_ids) OR EXISTS (
            SELECT 1 FROM @cdm_database_schema.CONCEPT_ANCESTOR ca
            WHERE ca.ancestor_concept_id IN (@indication_concept_ids) AND ca.descendant_concept_id = c.condition_concept_id))
          AND c.condition_start_date >= DATEADD(DAY, -@indication_days, s.index_date)
          AND c.condition_start_date < s.covariate_cutoff)
      AND NOT EXISTS (SELECT 1 FROM #fps_drug d WHERE d.person_id = s.person_id AND d.arm = -1
        AND d.index_date < s.index_date AND
        CASE WHEN d.end_date >= d.index_date THEN d.end_date ELSE d.index_date END >= DATEADD(DAY, -@washout_days, s.index_date))
      AND NOT EXISTS (SELECT 1 FROM concurrent c WHERE c.person_id = s.person_id AND c.index_date = s.index_date)
)
SELECT person_id AS subject_id, CASE WHEN arm = 1 THEN 1 ELSE 2 END AS cohort_definition_id,
       index_date AS cohort_start_date, index_date AS cohort_end_date, covariate_cutoff
INTO #fps_exposure FROM eligible WHERE sequence = 1;
CREATE UNIQUE CLUSTERED INDEX ix_exposure ON #fps_exposure(subject_id);
