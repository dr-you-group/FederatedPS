-- One local session per institution. Source tables are never modified.
-- Examine ALL positive institution IDs, not just the three configured sites.
-- fps-step: Aggregate all positive-site visits by patient (patient cap not applied)
SELECT person_id, MIN(care_site_id) AS care_site_id,
       MAX(care_site_id) AS last_care_site_id
INTO #fps_membership
FROM @cdm_database_schema.VISIT_OCCURRENCE
WHERE care_site_id IS NOT NULL AND care_site_id > 0
GROUP BY person_id;
-- fps-step: Index patient-to-institution membership
CREATE UNIQUE CLUSTERED INDEX ix_membership ON #fps_membership(person_id);

-- fps-step: Select patients exclusive to this site
SELECT person_id INTO #fps_person
FROM #fps_membership
WHERE care_site_id = last_care_site_id AND care_site_id = @care_site_id;
-- fps-step: Index exclusive patients
CREATE UNIQUE CLUSTERED INDEX ix_person ON #fps_person(person_id);

-- fps-step: Copy all visits of exclusive patients at this site
SELECT v.visit_occurrence_id, v.person_id, v.visit_concept_id,
       v.visit_start_date, v.visit_end_date, v.preceding_visit_occurrence_id
INTO #fps_visit
FROM @cdm_database_schema.VISIT_OCCURRENCE v
JOIN #fps_person p ON p.person_id = v.person_id
WHERE v.care_site_id = @care_site_id;
-- fps-step: Index visits by visit_occurrence_id
CREATE UNIQUE CLUSTERED INDEX ix_visit ON #fps_visit(visit_occurrence_id);
-- fps-step: Index visits by person_id
CREATE INDEX ix_visit_person ON #fps_visit(person_id);
