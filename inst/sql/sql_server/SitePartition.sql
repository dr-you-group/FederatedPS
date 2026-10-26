-- Restrict the working set to people with a dated, visit-linked exposure to
-- either study arm at this site. No whole-CDM membership GROUP BY is needed.
-- All positive institution IDs still count when excluding cross-site people.
-- fps-step: Find study-exposed patients at this site
SELECT d.person_id,
       MIN(CASE WHEN m.arm = 1 THEN d.drug_exposure_start_date END) AS first_target_date,
       MIN(CASE WHEN m.arm = 0 THEN d.drug_exposure_start_date END) AS first_comparator_date
INTO #fps_candidate
FROM @cdm_database_schema.DRUG_EXPOSURE d
JOIN #fps_drug_concepts m ON m.drug_concept_id = d.drug_concept_id AND m.arm >= 0
JOIN @cdm_database_schema.VISIT_OCCURRENCE v
  ON v.visit_occurrence_id = d.visit_occurrence_id AND v.person_id = d.person_id
WHERE v.care_site_id = @care_site_id AND d.drug_exposure_start_date IS NOT NULL
GROUP BY d.person_id;
-- fps-step: Index study-exposed patient candidates
CREATE UNIQUE CLUSTERED INDEX ix_candidate ON #fps_candidate(person_id);

-- A visit to ANY other positive care_site_id excludes a person, including
-- institutions outside the configured 1/2/3. NULL/zero/negative IDs do not.
-- fps-step: Exclude patients visiting any other positive institution
SELECT c.person_id INTO #fps_person
FROM #fps_candidate c
WHERE NOT EXISTS (
    SELECT 1 FROM @cdm_database_schema.VISIT_OCCURRENCE other_visit
    WHERE other_visit.person_id = c.person_id
      AND other_visit.care_site_id > 0 AND other_visit.care_site_id <> @care_site_id
);
-- fps-step: Index exclusive study candidates
CREATE UNIQUE CLUSTERED INDEX ix_person ON #fps_person(person_id);
