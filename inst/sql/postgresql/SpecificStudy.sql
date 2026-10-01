CREATE TEMP TABLE fps_products AS
WITH products AS MATERIALIZED (
    SELECT m.arm, m.ingredient_id, ca.descendant_concept_id AS drug_concept_id
    FROM fps_ingredients m
    JOIN @cdm_database_schema.concept_ancestor ca ON ca.ancestor_concept_id = m.ingredient_id
    WHERE m.arm >= 0
), ids AS (SELECT DISTINCT drug_concept_id FROM products), forms AS (
    SELECT cr.concept_id_1 AS drug_concept_id,
        bool_or(c.concept_name ILIKE '%oral%') AS oral,
        bool_or(c.concept_name ILIKE '%extended release%') AS extended_release,
        bool_or(c.concept_name ~* '\m(injection|injectable)\M') AS parenteral
    FROM @cdm_database_schema.concept_relationship cr
    JOIN ids ON ids.drug_concept_id = cr.concept_id_1
    JOIN @cdm_database_schema.concept c ON c.concept_id = cr.concept_id_2
    WHERE cr.relationship_id = 'RxNorm has dose form' AND cr.invalid_reason IS NULL
    GROUP BY cr.concept_id_1
), strength AS (
    SELECT ds.drug_concept_id, array_agg(DISTINCT ds.ingredient_concept_id::bigint) AS ingredients
    FROM @cdm_database_schema.drug_strength ds JOIN ids USING (drug_concept_id)
    GROUP BY ds.drug_concept_id
)
SELECT p.arm, p.drug_concept_id,
    bool_or(coalesce(
        CASE WHEN '@form_policy' = 'parenteral_single' THEN f.parenteral
             WHEN '@form_policy' = 'oral_ir_opioid' THEN f.oral AND NOT f.extended_release
             ELSE f.oral END
        AND s.ingredients IS NOT NULL
        AND s.ingredients <@ CASE WHEN '@form_policy' = 'oral_ir_opioid'
            THEN ARRAY[p.ingredient_id, 1125315::bigint, 1177480::bigint]
            ELSE ARRAY[p.ingredient_id] END, false)) AS eligible
FROM products p
LEFT JOIN forms f USING (drug_concept_id)
LEFT JOIN strength s USING (drug_concept_id)
GROUP BY p.arm, p.drug_concept_id;

CREATE TEMP TABLE fps_indication AS
SELECT DISTINCT c.concept_id FROM @cdm_database_schema.concept c
WHERE c.domain_id = 'Condition' AND c.standard_concept = 'S'
AND (c.concept_id IN (@indication_concept_ids) OR c.concept_id IN (
    SELECT descendant_concept_id FROM @cdm_database_schema.concept_ancestor
    WHERE ancestor_concept_id IN (@indication_concept_ids)));

CREATE TEMP TABLE fps_raw AS
SELECT d.person_id, d.drug_exposure_start_date AS index_date,
    d.visit_occurrence_id, p.arm, p.eligible
FROM @cdm_database_schema.drug_exposure d
JOIN fps_products p ON p.drug_concept_id = d.drug_concept_id
WHERE d.drug_type_concept_id IN (@record_type_concept_ids)
    AND d.drug_exposure_start_date IS NOT NULL;
CREATE INDEX ON fps_raw (person_id, index_date);
ANALYZE fps_raw;

CREATE TEMP TABLE fps_exposure AS
WITH concurrent AS (
    -- Same-day opposite-arm records exclude the date even if their form fails.
    SELECT person_id, index_date FROM fps_raw
    GROUP BY person_id, index_date HAVING count(DISTINCT arm) > 1
), starts AS (
    SELECT r.person_id, r.index_date, r.arm,
        min(least(r.index_date, CASE WHEN v.visit_concept_id IN (9201, 9203, 262)
            THEN least(v.visit_start_date, CASE WHEN pv.visit_concept_id IN (9203, 262)
                AND pv.visit_end_date >= v.visit_start_date - 1
                THEN pv.visit_start_date ELSE v.visit_start_date END)
            ELSE r.index_date END)) AS covariate_cutoff
    FROM fps_raw r
    LEFT JOIN @cdm_database_schema.visit_occurrence v ON v.visit_occurrence_id = r.visit_occurrence_id
    LEFT JOIN @cdm_database_schema.visit_occurrence pv ON pv.visit_occurrence_id = v.preceding_visit_occurrence_id
    WHERE r.eligible
    GROUP BY r.person_id, r.index_date, r.arm
), eligible AS (
    SELECT s.*, row_number() OVER (PARTITION BY s.person_id ORDER BY s.index_date, s.arm DESC) AS sequence
    FROM starts s JOIN @cdm_database_schema.person p ON p.person_id = s.person_id
    WHERE extract(year FROM age(s.index_date, make_date(p.year_of_birth::int,
        coalesce(p.month_of_birth, 1)::int, coalesce(p.day_of_birth, 1)::int))) >= @min_age
    AND EXISTS (
        SELECT 1 FROM @cdm_database_schema.observation_period o
        WHERE o.person_id = s.person_id
            AND s.index_date BETWEEN o.observation_period_start_date + @prior_days AND o.observation_period_end_date)
    AND EXISTS (
        SELECT 1 FROM @cdm_database_schema.condition_occurrence c
        JOIN fps_indication i ON i.concept_id = c.condition_concept_id
        WHERE c.person_id = s.person_id AND c.condition_start_date >= s.index_date - @indication_days
            AND c.condition_start_date < s.covariate_cutoff)
    AND NOT EXISTS (
        SELECT 1 FROM @cdm_database_schema.drug_era d
        JOIN fps_ingredients w ON w.ingredient_id = d.drug_concept_id AND w.arm = -1
        WHERE d.person_id = s.person_id AND d.drug_era_start_date < s.index_date
            AND greatest(d.drug_era_start_date, coalesce(d.drug_era_end_date, d.drug_era_start_date))
                >= s.index_date - @washout_days)
    AND NOT EXISTS (
        SELECT 1 FROM concurrent c WHERE c.person_id = s.person_id AND c.index_date = s.index_date)
)
SELECT person_id AS subject_id, CASE WHEN arm = 1 THEN 1 ELSE 2 END AS cohort_definition_id,
    index_date AS cohort_start_date, index_date AS cohort_end_date, covariate_cutoff
FROM eligible WHERE sequence = 1;
CREATE UNIQUE INDEX ON fps_exposure (subject_id);
ANALYZE fps_exposure;
