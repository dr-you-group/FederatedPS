-- CohortMethod subsequently selects first use BEFORE age/observation filters.
CREATE TEMP TABLE fps_exposure AS
SELECT d.person_id AS subject_id,
    CASE WHEN m.arm = 1 THEN 1 ELSE 2 END AS cohort_definition_id,
    d.drug_era_start_date AS cohort_start_date,
    d.drug_era_end_date AS cohort_end_date
FROM @cdm_database_schema.drug_era d
JOIN fps_ingredients m ON m.ingredient_id = d.drug_concept_id AND m.arm >= 0;
