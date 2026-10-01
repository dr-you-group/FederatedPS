-- Resolve the same ingredient/ATC definitions in the local vocabulary.
CREATE TEMP TABLE fps_requested_ingredients AS
SELECT DISTINCT arm, ingredient_id::bigint
FROM (VALUES @ingredient_rows) x(arm, ingredient_id)
WHERE ingredient_id <> 0;

CREATE TEMP TABLE fps_requested_atc AS
SELECT DISTINCT arm, code FROM (VALUES @atc_rows) x(arm, code)
WHERE code <> '';

CREATE TEMP TABLE fps_atc_ingredients AS
SELECT DISTINCT r.arm, r.code, i.concept_id AS ingredient_id
FROM fps_requested_atc r
JOIN @cdm_database_schema.concept c ON c.vocabulary_id = 'ATC' AND c.concept_code = r.code
JOIN @cdm_database_schema.concept_ancestor ca ON ca.ancestor_concept_id = c.concept_id
JOIN @cdm_database_schema.concept i ON i.concept_id = ca.descendant_concept_id
WHERE i.concept_class_id = 'Ingredient' AND i.vocabulary_id IN ('RxNorm', 'RxNorm Extension');

CREATE TEMP TABLE fps_ingredients AS
SELECT arm, ingredient_id FROM fps_requested_ingredients
UNION
SELECT arm, ingredient_id FROM fps_atc_ingredients;
