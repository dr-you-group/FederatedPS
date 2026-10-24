-- One local session per institution. Source tables are never modified.
-- Examine ALL positive institution IDs, not just the three configured sites.
SELECT person_id, MIN(care_site_id) AS care_site_id,
       COUNT(DISTINCT care_site_id) AS institution_count
INTO #fps_membership
FROM @cdm_database_schema.VISIT_OCCURRENCE
WHERE care_site_id IS NOT NULL AND care_site_id > 0
GROUP BY person_id;
CREATE UNIQUE CLUSTERED INDEX ix_membership ON #fps_membership(person_id);

SELECT person_id INTO #fps_person
FROM #fps_membership
WHERE institution_count = 1 AND care_site_id = @care_site_id;
CREATE UNIQUE CLUSTERED INDEX ix_person ON #fps_person(person_id);

SELECT v.* INTO #fps_visit
FROM @cdm_database_schema.VISIT_OCCURRENCE v
JOIN #fps_person p ON p.person_id = v.person_id
WHERE v.care_site_id = @care_site_id;
CREATE UNIQUE CLUSTERED INDEX ix_visit ON #fps_visit(visit_occurrence_id);
CREATE INDEX ix_visit_person ON #fps_visit(person_id);
