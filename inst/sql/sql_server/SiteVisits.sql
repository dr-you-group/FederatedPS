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
