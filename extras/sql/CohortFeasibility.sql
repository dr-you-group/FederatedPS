-- E1-followup: one schema/connection/snapshot at a time. These SELECTs are
-- materialized only into session-local pg_temp objects by the R driver.
-- Patient rows never leave PostgreSQL. @cdm_schema is a quoted identifier.

-- @step exposures
SELECT d.person_id, d.drug_exposure_start_date AS start_date,
    d.drug_type_concept_id, m.ingredient_id,
    (m.single_ingredient AND d.drug_exposure_start_date IS NOT NULL
        AND d.drug_exposure_end_date IS NOT NULL
        AND isfinite(d.drug_exposure_start_date) AND isfinite(d.drug_exposure_end_date)
        AND d.drug_exposure_end_date>=d.drug_exposure_start_date
        AND (d.drug_exposure_start_datetime IS NULL OR
            (isfinite(d.drug_exposure_start_datetime)
                AND d.drug_exposure_start_datetime::date=d.drug_exposure_start_date))
        AND (d.drug_exposure_end_datetime IS NULL OR
            (isfinite(d.drug_exposure_end_datetime)
                AND d.drug_exposure_end_datetime::date=d.drug_exposure_end_date))
        AND (d.drug_exposure_start_datetime IS NULL OR d.drug_exposure_end_datetime IS NULL
            OR d.drug_exposure_end_datetime>=d.drug_exposure_start_datetime)) AS eligible
FROM @cdm_schema.drug_exposure d
JOIN pg_temp.e1_definitions m ON m.drug_concept_id=d.drug_concept_id

-- @step first
-- MIN per ingredient avoids joining every eligible record back to first_dates.
-- PostgreSQL LEAST ignores NULL: one ingredient alone still defines an index.
WITH dates AS (
    SELECT person_id,
        min(start_date) FILTER (WHERE eligible AND ingredient_id=1545958) AS target_date,
        min(start_date) FILTER (WHERE eligible AND ingredient_id=1539403) AS comparator_date
    FROM pg_temp.e1_exposures GROUP BY person_id HAVING bool_or(eligible)
)
SELECT person_id, least(target_date,comparator_date) AS index_date,
    CASE WHEN comparator_date IS NULL OR target_date<comparator_date
        THEN 1545958 ELSE 1539403 END AS ingredient_id,
    CASE WHEN target_date=comparator_date THEN 2 ELSE 1 END AS treatments
FROM dates

-- @step age
WITH birth AS (
    SELECT f.*, p.year_of_birth, p.month_of_birth, p.day_of_birth, p.birth_datetime,
        (p.month_of_birth IS NOT NULL AND p.day_of_birth IS NOT NULL) AS complete_birth,
        CASE WHEN p.year_of_birth BETWEEN 1 AND 9999
            AND p.month_of_birth BETWEEN 1 AND 12 AND p.day_of_birth BETWEEN 1 AND 31
            THEN make_date(p.year_of_birth,p.month_of_birth,1)+(p.day_of_birth-1) END AS recorded_birth
    FROM pg_temp.e1_first f JOIN @cdm_schema.person p USING(person_id)
    WHERE f.treatments=1
)
SELECT person_id,index_date,ingredient_id,treatments,complete_birth,CASE
    WHEN complete_birth AND recorded_birth IS NOT NULL
        AND extract(month FROM recorded_birth)=month_of_birth
        AND (birth_datetime IS NULL OR (isfinite(birth_datetime) AND birth_datetime::date=recorded_birth))
        THEN extract(year FROM age(index_date,recorded_birth))
    -- Preserve E1's year-difference approximation; no missing date imputation.
    WHEN NOT complete_birth AND year_of_birth BETWEEN 1 AND extract(year FROM index_date)
        AND (birth_datetime IS NULL OR (isfinite(birth_datetime)
            AND extract(year FROM birth_datetime)=year_of_birth))
        THEN extract(year FROM index_date)-year_of_birth
    END AS age
FROM birth

-- @step visits
-- Retain prior-history flags in the same visit scan. Missing/invalid visits
-- do not disappear from attrition: the next step LEFT JOINs these flags.
SELECT a.person_id,
    count(*) FILTER (WHERE v.visit_end_date BETWEEN a.index_date-90 AND a.index_date-1) AS baseline_visits,
    bool_or(v.visit_end_date<a.index_date) AS any_prior_visit,
    bool_or(v.visit_end_date<a.index_date-90) AS earlier_than_baseline
FROM pg_temp.e1_age a JOIN @cdm_schema.visit_occurrence v USING(person_id)
WHERE a.age>=65 AND v.visit_start_date IS NOT NULL AND v.visit_end_date IS NOT NULL
    AND isfinite(v.visit_start_date) AND isfinite(v.visit_end_date)
    AND v.visit_start_date<=v.visit_end_date
GROUP BY a.person_id

-- @step cohort
SELECT a.*, coalesce(v.baseline_visits,0) AS baseline_visits,
    coalesce(v.any_prior_visit,FALSE) AS any_prior_visit,
    coalesce(v.earlier_than_baseline,FALSE) AS earlier_than_baseline
FROM pg_temp.e1_age a LEFT JOIN pg_temp.e1_visits v USING(person_id)

-- @step final
SELECT * FROM pg_temp.e1_cohort WHERE age>=65 AND baseline_visits>0

-- @step attrition
WITH counts AS (
    SELECT 'attrition' AS section,'01_any_study_ingredient' AS metric,
        ingredient_id,count(DISTINCT person_id) AS value
    FROM pg_temp.e1_exposures GROUP BY ingredient_id
    UNION ALL
    SELECT 'attrition','02_single_ingredient_valid_dates',ingredient_id,count(DISTINCT person_id)
    FROM pg_temp.e1_exposures WHERE eligible GROUP BY ingredient_id
    UNION ALL
    SELECT 'attrition','03_first_date_unambiguous',ingredient_id,count(*)
    FROM pg_temp.e1_first WHERE treatments=1 GROUP BY ingredient_id
    UNION ALL
    SELECT 'attrition','04_first_date_both_excluded',NULL,count(*) FROM pg_temp.e1_first WHERE treatments>1
    UNION ALL
    SELECT 'attrition','05_age_65_or_older',ingredient_id,count(*)
    FROM pg_temp.e1_cohort WHERE age>=65 GROUP BY ingredient_id
    UNION ALL
    SELECT 'attrition','06_baseline_visit_final',ingredient_id,count(*) FROM pg_temp.e1_final GROUP BY ingredient_id
    UNION ALL
    SELECT 'exclusion','unknown_or_inconsistent_age',ingredient_id,count(*)
    FROM pg_temp.e1_cohort WHERE age IS NULL GROUP BY ingredient_id
    UNION ALL
    SELECT 'exclusion','age_below_65',ingredient_id,count(*)
    FROM pg_temp.e1_cohort WHERE age<65 GROUP BY ingredient_id
    UNION ALL
    SELECT 'exclusion','no_baseline_visit_after_age',ingredient_id,count(*)
    FROM pg_temp.e1_cohort WHERE age>=65 AND baseline_visits=0 GROUP BY ingredient_id
    UNION ALL
    SELECT 'availability','final_incomplete_birth_year_approximation',ingredient_id,count(*)
    FROM pg_temp.e1_final WHERE NOT complete_birth GROUP BY ingredient_id
    UNION ALL
    SELECT 'validation','duplicate_first_person',NULL,count(*)-count(DISTINCT person_id) FROM pg_temp.e1_first
    UNION ALL
    SELECT 'validation','duplicate_final_person',NULL,count(*)-count(DISTINCT person_id) FROM pg_temp.e1_final
    UNION ALL
    SELECT 'validation','ambiguous_final_person',NULL,count(*) FROM pg_temp.e1_final WHERE treatments<>1
    UNION ALL
    SELECT 'validation','index_changed',NULL,count(*) FROM pg_temp.e1_final f
    JOIN pg_temp.e1_first d USING(person_id) WHERE f.index_date<>d.index_date
    UNION ALL
    SELECT 'validation','assignment_partition',NULL,
        count(*)-count(*) FILTER (WHERE treatments=1)-count(*) FILTER (WHERE treatments=2)
    FROM pg_temp.e1_first
    UNION ALL
    SELECT 'validation','missing_person_record',NULL,count(*) FROM pg_temp.e1_first f
    LEFT JOIN pg_temp.e1_age a USING(person_id) WHERE f.treatments=1 AND a.person_id IS NULL
), required AS (
    SELECT 'attrition' AS section,m.metric,i.ingredient_id FROM
        (VALUES ('01_any_study_ingredient'),('02_single_ingredient_valid_dates'),
            ('03_first_date_unambiguous'),('05_age_65_or_older'),('06_baseline_visit_final')) m(metric)
        CROSS JOIN (VALUES (1545958),(1539403)) i(ingredient_id)
)
SELECT c.section,c.metric,c.ingredient_id,c.value FROM counts c
UNION ALL
SELECT r.section,r.metric,r.ingredient_id,0::bigint FROM required r
WHERE NOT EXISTS (SELECT 1 FROM counts c WHERE c.section=r.section
    AND c.metric=r.metric AND c.ingredient_id=r.ingredient_id)

-- @step observation
WITH flags AS (
    SELECT f.person_id,f.ingredient_id,
        bool_or(op.observation_period_start_date<=f.index_date
            AND op.observation_period_end_date>=f.index_date) AS covers_index,
        bool_or(op.observation_period_start_date<=f.index_date-90
            AND op.observation_period_end_date>=f.index_date) AS prior_90
    FROM pg_temp.e1_final f LEFT JOIN @cdm_schema.observation_period op
        ON op.person_id=f.person_id AND isfinite(op.observation_period_start_date)
        AND isfinite(op.observation_period_end_date)
        AND op.observation_period_start_date<=op.observation_period_end_date
    GROUP BY f.person_id,f.ingredient_id
), counts AS (
    SELECT ingredient_id,'index_in_observation_period' AS metric,count(*) FILTER (WHERE covers_index) AS value
    FROM flags GROUP BY ingredient_id
    UNION ALL
    SELECT ingredient_id,'recorded_90_day_prior_observation',count(*) FILTER (WHERE prior_90)
    FROM flags GROUP BY ingredient_id
    UNION ALL
    SELECT ingredient_id,'baseline_visit',count(*) FILTER (WHERE baseline_visits>0)
    FROM pg_temp.e1_final GROUP BY ingredient_id
    UNION ALL
    SELECT ingredient_id,'any_prior_valid_visit',count(*) FILTER (WHERE any_prior_visit)
    FROM pg_temp.e1_final GROUP BY ingredient_id
    UNION ALL
    SELECT ingredient_id,'visit_before_baseline',count(*) FILTER (WHERE earlier_than_baseline)
    FROM pg_temp.e1_final GROUP BY ingredient_id
)
SELECT 'availability' AS section,metric,ingredient_id,value FROM counts

-- @step domain
-- Only the fixed three domain identifiers in the R script are substituted.
-- These flags deliberately preserve E1's baseline-or-missing-date denominator.
WITH records AS (
    SELECT f.person_id,f.ingredient_id,f.index_date,d.@event_date AS event_date,
        d.@event_datetime AS event_datetime,d.visit_occurrence_id
    FROM pg_temp.e1_final f JOIN @cdm_schema.@domain_table d USING(person_id)
    WHERE d.@event_date BETWEEN f.index_date-90 AND f.index_date-1 OR d.@event_date IS NULL
), flags AS (
    SELECT d.person_id,d.ingredient_id,
        bool_or(d.event_date IS NOT NULL) AS baseline_record,
        bool_or(d.event_date IS NULL) AS missing_date_any_history,
        bool_or(d.event_date IS NOT NULL AND v.visit_occurrence_id IS NOT NULL) AS linked_visit,
        bool_or(d.event_date IS NOT NULL AND v.visit_start_date<=d.index_date
            AND v.visit_end_date>=d.index_date) AS index_episode,
        bool_or(d.event_date IS NOT NULL AND d.event_date=v.visit_start_date) AS dated_at_visit_start,
        bool_or(d.event_datetime IS NOT NULL) AS has_datetime,
        bool_or(d.event_datetime IS NOT NULL AND d.event_datetime::date<>d.event_date) AS date_disagreement
    FROM records d LEFT JOIN @cdm_schema.visit_occurrence v
        ON v.visit_occurrence_id=d.visit_occurrence_id AND v.person_id=d.person_id
    GROUP BY d.person_id,d.ingredient_id
)
SELECT 'domain' AS section,v.metric,d.ingredient_id,count(*) AS value FROM flags d
CROSS JOIN LATERAL (VALUES ('baseline_record',d.baseline_record),
    ('missing_date_any_history',d.missing_date_any_history),('linked_visit',d.linked_visit),
    ('index_episode',d.index_episode),('dated_at_visit_start',d.dated_at_visit_start),
    ('has_datetime',d.has_datetime),('date_disagreement',d.date_disagreement)) v(metric,present)
WHERE v.present GROUP BY v.metric,d.ingredient_id

-- @step drug_types
SELECT e.ingredient_id,e.drug_type_concept_id,c.concept_name AS drug_type_name,
    count(*) AS study_exposure_records,count(DISTINCT e.person_id) AS study_exposed_persons,
    count(*) FILTER (WHERE e.eligible) AS eligible_exposure_records,
    count(DISTINCT e.person_id) FILTER (WHERE e.eligible) AS eligible_exposed_persons
FROM pg_temp.e1_exposures e LEFT JOIN @cdm_schema.concept c ON c.concept_id=e.drug_type_concept_id
GROUP BY e.ingredient_id,e.drug_type_concept_id,c.concept_name

-- @step synthetic_sources
-- Entirely invented SQL VALUES, never a subset of actual patient records.
fixture_definitions AS (
    SELECT DISTINCT * FROM (VALUES (100,1545958,TRUE),(100,1545958,TRUE),
        (200,1539403,TRUE),(300,1545958,FALSE),(300,1539403,FALSE))
        v(drug_concept_id,ingredient_id,single_ingredient)
), fixture_drug_exposure AS (
    SELECT person_id,drug_concept_id,s::date AS drug_exposure_start_date,
        e::date AS drug_exposure_end_date,t::timestamp AS drug_exposure_start_datetime,
        NULL::timestamp AS drug_exposure_end_datetime,32838 AS drug_type_concept_id
    FROM (VALUES
        (1,100,'2020-04-01','2020-04-01',NULL),(1,100,'2020-04-01','2020-04-01',NULL),
        (2,100,'2020-04-01','2020-04-01',NULL),(2,200,'2020-05-01','2020-05-01',NULL),
        (3,200,'2020-03-01','2020-03-01',NULL),(3,100,'2020-04-01','2020-04-01',NULL),
        (4,100,'2020-04-01','2020-04-01',NULL),(4,200,'2020-04-01','2020-04-01',NULL),
        (4,100,'2020-06-01','2020-06-01',NULL),
        (5,100,'2019-04-01','2019-04-01',NULL),(5,100,'2020-04-01','2020-04-01',NULL),
        (6,100,'2020-04-01','2020-04-01',NULL),(6,100,'2020-06-01','2020-06-01',NULL),
        (7,100,'2020-04-01','2020-04-01',NULL),(8,100,'2020-04-01','2020-04-01',NULL),
        (9,100,'2020-04-01','2020-04-01',NULL),(10,100,'2020-04-01','2020-04-01',NULL),
        (11,100,'2020-04-01','2020-04-01',NULL),(12,100,'2020-04-01','2020-04-01',NULL),
        (13,100,'2020-04-01','2020-03-31',NULL),(13,200,'2020-04-03','2020-04-03',NULL),
        (14,100,'2020-04-01','2020-04-01','2020-04-02 01:00:00'),
        (15,100,'2020-04-01','2020-04-01',NULL),(16,100,'2020-04-01','2020-04-01',NULL),
        (17,300,'2020-03-01','2020-03-01',NULL),(17,100,'2020-04-01','2020-04-01',NULL),
        (18,200,'2020-04-01','2020-04-01',NULL),(18,200,'2020-04-01','2020-04-01',NULL),
        (19,100,'infinity','infinity',NULL),(20,100,NULL,NULL,NULL),
        (22,100,'2020-04-01','2020-04-01',NULL),(23,100,'2020-04-01','2020-04-01',NULL)
    ) v(person_id,drug_concept_id,s,e,t)
), fixture_person AS (
    SELECT person_id,1955 AS year_of_birth,
        CASE WHEN person_id IN (15,23) THEN NULL WHEN person_id=16 THEN 2 ELSE 4 END AS month_of_birth,
        CASE WHEN person_id IN (15,23) THEN NULL WHEN person_id=7 THEN 2
            WHEN person_id=16 THEN 30 ELSE 1 END AS day_of_birth,
        CASE WHEN person_id IN (22,23) THEN timestamp '1954-04-01' END AS birth_datetime
    FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),
        (14),(15),(16),(17),(18),(19),(20),(22),(23)) v(person_id)
), fixture_visit_occurrence AS (
    SELECT person_id,s::date AS visit_start_date,e::date AS visit_end_date FROM (VALUES
        (1,'2020-01-01','2020-01-02'),(2,'2020-03-30','2020-03-31'),
        (3,'2020-02-28','2020-02-29'),(5,'2019-03-01','2019-03-02'),
        (6,'2020-04-01','2020-04-02'),(7,'2020-03-30','2020-03-31'),
        (8,'2020-03-30','2020-03-31'),(9,'2020-03-31','2020-04-01'),
        (11,'2020-03-31','2020-03-30'),(12,'2020-03-01',NULL),
        (13,'2020-04-01','2020-04-02'),(15,'2020-03-30','2020-03-31'),
        (16,'2020-03-30','2020-03-31'),(17,'2020-03-30','2020-03-31'),
        (18,'2020-03-30','2020-03-31'),(22,'2020-03-30','2020-03-31'),
        (23,'2020-03-30','2020-03-31')) v(person_id,s,e)
)

-- @step synthetic_original_first
-- Original E1 first_dates + self-join logic, independent of per-drug MIN.
WITH eligible AS (SELECT person_id,start_date,ingredient_id FROM exposures WHERE eligible),
first_dates AS (SELECT person_id,min(start_date) AS index_date FROM eligible GROUP BY person_id)
SELECT f.person_id,f.index_date,min(e.ingredient_id) AS ingredient_id,
    count(DISTINCT e.ingredient_id) AS treatments
FROM first_dates f JOIN eligible e ON e.person_id=f.person_id AND e.start_date=f.index_date
GROUP BY f.person_id,f.index_date

-- @step synthetic_expected
SELECT person_id,d::date AS index_date,ingredient_id,treatments,age::numeric,
    baseline_visits::bigint,final_member FROM (VALUES
    (1,'2020-04-01',1545958,1,65,1,TRUE),(2,'2020-04-01',1545958,1,65,1,TRUE),
    (3,'2020-03-01',1539403,1,64,0,FALSE),(4,'2020-04-01',1539403,2,NULL,0,FALSE),
    (5,'2019-04-01',1545958,1,64,0,FALSE),(6,'2020-04-01',1545958,1,65,0,FALSE),
    (7,'2020-04-01',1545958,1,64,0,FALSE),(8,'2020-04-01',1545958,1,65,1,TRUE),
    (9,'2020-04-01',1545958,1,65,0,FALSE),(10,'2020-04-01',1545958,1,65,0,FALSE),
    (11,'2020-04-01',1545958,1,65,0,FALSE),(12,'2020-04-01',1545958,1,65,0,FALSE),
    (13,'2020-04-03',1539403,1,65,1,TRUE),(15,'2020-04-01',1545958,1,65,1,TRUE),
    (16,'2020-04-01',1545958,1,NULL,0,FALSE),(17,'2020-04-01',1545958,1,65,1,TRUE),
    (18,'2020-04-01',1539403,1,65,1,TRUE),(22,'2020-04-01',1545958,1,NULL,0,FALSE),
    (23,'2020-04-01',1545958,1,NULL,0,FALSE)
) v(person_id,d,ingredient_id,treatments,age,baseline_visits,final_member)
