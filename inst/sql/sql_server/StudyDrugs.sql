-- Drug eras have no visit/institution key. Use only visit-attributed exposures.
SELECT d.person_id, d.drug_concept_id, d.drug_exposure_start_date AS index_date,
       d.drug_exposure_end_date AS end_date, d.visit_occurrence_id,
       d.drug_type_concept_id, m.arm, m.ingredient_id
INTO #fps_drug
FROM @cdm_database_schema.DRUG_EXPOSURE d
JOIN #fps_visit v ON v.visit_occurrence_id = d.visit_occurrence_id AND v.person_id = d.person_id
JOIN #fps_drug_concepts m ON m.drug_concept_id = d.drug_concept_id
WHERE d.drug_exposure_start_date IS NOT NULL;
CREATE INDEX ix_drug ON #fps_drug(person_id, index_date);
