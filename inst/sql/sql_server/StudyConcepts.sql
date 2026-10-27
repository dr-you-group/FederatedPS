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

-- Resolve the small vocabulary mapping before touching clinical rows.
SELECT DISTINCT m.arm, m.ingredient_id, ca.descendant_concept_id AS drug_concept_id
INTO #fps_drug_concepts
FROM #fps_ingredients m
JOIN @cdm_database_schema.CONCEPT_ANCESTOR ca ON ca.ancestor_concept_id = m.ingredient_id;
CREATE INDEX ix_drug_concepts ON #fps_drug_concepts(drug_concept_id, arm);
