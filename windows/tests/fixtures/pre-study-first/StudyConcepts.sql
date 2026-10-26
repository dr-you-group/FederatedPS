SELECT DISTINCT arm, CAST(ingredient_id AS BIGINT) AS ingredient_id
INTO #fps_requested_ingredients
FROM (VALUES @ingredient_rows) x(arm, ingredient_id) WHERE ingredient_id <> 0;
SELECT DISTINCT arm, code INTO #fps_requested_atc
FROM (VALUES @atc_rows) x(arm, code) WHERE code <> '';
SELECT DISTINCT r.arm, r.code, i.concept_id AS ingredient_id
INTO #fps_atc_ingredients
FROM #fps_requested_atc r
JOIN @cdm_database_schema.CONCEPT c ON c.vocabulary_id = 'ATC' AND c.concept_code = r.code
JOIN @cdm_database_schema.CONCEPT_ANCESTOR ca ON ca.ancestor_concept_id = c.concept_id
JOIN @cdm_database_schema.CONCEPT i ON i.concept_id = ca.descendant_concept_id
WHERE i.concept_class_id = 'Ingredient' AND i.vocabulary_id IN ('RxNorm', 'RxNorm Extension');
SELECT arm, ingredient_id INTO #fps_ingredients FROM #fps_requested_ingredients
UNION SELECT arm, ingredient_id FROM #fps_atc_ingredients;

-- Drug eras have no visit/institution key. Use only visit-attributed exposures.
SELECT d.person_id, d.drug_concept_id, d.drug_exposure_start_date AS index_date,
       d.drug_exposure_end_date AS end_date, d.visit_occurrence_id,
       d.drug_type_concept_id, m.arm, m.ingredient_id
INTO #fps_drug
FROM @cdm_database_schema.DRUG_EXPOSURE d
JOIN #fps_visit v ON v.visit_occurrence_id = d.visit_occurrence_id AND v.person_id = d.person_id
JOIN @cdm_database_schema.CONCEPT_ANCESTOR ca ON ca.descendant_concept_id = d.drug_concept_id
JOIN #fps_ingredients m ON m.ingredient_id = ca.ancestor_concept_id
WHERE d.drug_exposure_start_date IS NOT NULL;
CREATE INDEX ix_drug ON #fps_drug(person_id, index_date);
