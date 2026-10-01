-- Session-local views preserve index for age/window anchors while excluding
-- records from the linked acute episode. No source CDM tables are modified.
CREATE TEMP VIEW person AS SELECT * FROM @cdm_database_schema.person;
CREATE TEMP VIEW concept AS SELECT * FROM @cdm_database_schema.concept;
CREATE TEMP VIEW concept_ancestor AS SELECT * FROM @cdm_database_schema.concept_ancestor;

CREATE TEMP VIEW condition_occurrence AS
SELECT d.* FROM @cdm_database_schema.condition_occurrence d
JOIN fps_exposure c ON c.subject_id = d.person_id
WHERE d.condition_start_date >= c.cohort_start_date - @prior_days
    AND d.condition_start_date < c.covariate_cutoff;

CREATE TEMP VIEW drug_exposure AS
SELECT d.* FROM @cdm_database_schema.drug_exposure d
JOIN fps_exposure c ON c.subject_id = d.person_id
WHERE d.drug_exposure_start_date >= c.cohort_start_date - @prior_days
    AND d.drug_exposure_start_date < c.covariate_cutoff;

CREATE TEMP VIEW procedure_occurrence AS
SELECT d.* FROM @cdm_database_schema.procedure_occurrence d
JOIN fps_exposure c ON c.subject_id = d.person_id
WHERE d.procedure_date >= c.cohort_start_date - @prior_days
    AND d.procedure_date < c.covariate_cutoff;

CREATE TEMP VIEW measurement AS
SELECT d.* FROM @cdm_database_schema.measurement d
JOIN fps_exposure c ON c.subject_id = d.person_id
WHERE d.measurement_date >= c.cohort_start_date - @prior_days
    AND d.measurement_date < c.covariate_cutoff;
