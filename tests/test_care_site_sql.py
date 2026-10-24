"""Offline logical SQL tests on synthetic rows (no clinical data or credentials).

Developer dependencies: Python duckdb, sqlglot and base R. Run from repository root:
    python tests/test_care_site_sql.py --r Rscript
T-SQL is parsed and translated to DuckDB; this is not a live SQL Server test.
Index DDL is skipped. All selection/join/window expressions are executed.
"""
import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

import duckdb
import sqlglot
from sqlglot import exp

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "inst/sql/sql_server"


def render(file, **params):
    text = (SQL / file).read_text()
    params = {"cdm_database_schema": "cdm", **params}
    return re.sub(r"@(\w+)", lambda m: str(params[m[1]]), text)


def execute(db, text):
    text = re.sub(r"CREATE\s+(?:UNIQUE\s+)?(?:CLUSTERED\s+)?INDEX\s+[^;]+;", "", text, flags=re.I)
    for statement in sqlglot.parse(text, read="tsql"):
        if statement is None:
            continue
        if isinstance(statement, exp.Create) and statement.args.get("kind") == "INDEX":
            continue
        db.execute(statement.sql(dialect="duckdb"))


def fixture():
    db = duckdb.connect()
    db.execute("CREATE SCHEMA cdm")
    db.execute("CREATE TABLE cdm.person(person_id BIGINT, year_of_birth INT, month_of_birth INT, day_of_birth INT, gender_concept_id INT)")
    db.execute("CREATE TABLE cdm.visit_occurrence(visit_occurrence_id BIGINT, person_id BIGINT, care_site_id INT, visit_concept_id INT, visit_start_date DATE, visit_end_date DATE, preceding_visit_occurrence_id BIGINT)")
    db.execute("CREATE TABLE cdm.observation_period(person_id BIGINT, observation_period_start_date DATE, observation_period_end_date DATE)")
    db.execute("CREATE TABLE cdm.drug_exposure(person_id BIGINT, drug_concept_id INT, drug_exposure_start_date DATE, drug_exposure_end_date DATE, visit_occurrence_id BIGINT, drug_type_concept_id INT)")
    db.execute("CREATE TABLE cdm.condition_occurrence(person_id BIGINT, condition_concept_id INT, condition_start_date DATE, visit_occurrence_id BIGINT)")
    db.execute("CREATE TABLE cdm.procedure_occurrence(person_id BIGINT, procedure_concept_id INT, procedure_date DATE, visit_occurrence_id BIGINT)")
    db.execute("CREATE TABLE cdm.measurement(person_id BIGINT, measurement_concept_id INT, measurement_date DATE, visit_occurrence_id BIGINT)")
    db.execute("CREATE TABLE cdm.concept(concept_id INT, concept_name VARCHAR, concept_class_id VARCHAR, vocabulary_id VARCHAR, concept_code VARCHAR, domain_id VARCHAR, standard_concept VARCHAR)")
    db.execute("CREATE TABLE cdm.concept_ancestor(ancestor_concept_id INT, descendant_concept_id INT)")
    db.execute("CREATE TABLE cdm.concept_relationship(concept_id_1 INT, concept_id_2 INT, relationship_id VARCHAR, invalid_reason VARCHAR)")
    db.execute("CREATE TABLE cdm.drug_strength(drug_concept_id INT, ingredient_concept_id INT)")
    # Three valid single-institution patients; cross-site persons 4 and 6;
    # unknown institution only: 7; one known plus an unknown visit: 5.
    memberships = [(1, 1), (2, 2), (3, 3), (4, 1), (4, 2), (5, 1), (5, None),
                   (6, 1), (6, 4), (7, None)] + [(i, 1) for i in range(8, 14)]
    db.executemany("INSERT INTO cdm.person VALUES (?,1980,1,1,8507)", [(i,) for i in range(1, 14)])
    db.executemany("INSERT INTO cdm.observation_period VALUES (?,'2018-01-01','2021-12-31')", [(i,) for i in range(1, 14)])
    visits = {}
    for n, (person, site) in enumerate(memberships, 1):
        visits[person, site] = n
        db.execute("INSERT INTO cdm.visit_occurrence VALUES (?,?,?,9202,'2020-01-01','2020-12-31',NULL)", [n, person, site])
    def drug(person, concept=101, start="2020-06-01", visit=None, record_type=32818):
        if visit is None:
            visit = visits[person, {2: 2, 3: 3, 7: None}.get(person, 1)]
        db.execute("INSERT INTO cdm.drug_exposure VALUES (?,?,?,?,?,?)", [person, concept, start, start, visit, record_type])
    for person in range(1, 14):
        drug(person, concept=201 if person in (2, 5) else 101)
        db.execute("INSERT INTO cdm.condition_occurrence VALUES (?,500,'2020-04-01',?)", [person, visits[person, {2: 2, 3: 3, 7: None}.get(person, 1)]])
    # Never let unlinked / wrong-person / unknown-care-site events become index or features.
    drug(1, start="2019-01-01", visit=999999)
    drug(1, start="2019-02-01", visit=visits[2, 2])
    drug(5, start="2019-03-01", visit=visits[5, None])
    db.execute("INSERT INTO cdm.drug_exposure VALUES (1,101,'2019-04-01','2019-04-01',NULL,32818)")
    for concept, visit in [(600, visits[1, 1]), (601, None), (602, visits[2, 2]), (603, 999999)]:
        db.execute("INSERT INTO cdm.measurement VALUES (1,?,'2020-05-01',?)", [concept, visit])
    db.execute("INSERT INTO cdm.measurement VALUES (5,604,'2020-05-01',?)", [visits[5, None]])
    # Binary duplicates collapse; index-day and old records are outside the window.
    db.execute("INSERT INTO cdm.measurement VALUES (1,600,'2020-05-02',?), (1,605,'2020-06-01',?), (1,606,'2019-01-01',?)", [visits[1, 1]] * 3)
    db.execute("INSERT INTO cdm.procedure_occurrence VALUES (1,700,'2020-05-01',?)", [visits[1, 1]])
    drug(1, concept=300, start="2020-05-01")
    # A prior record not eligible as index still counts toward washout.
    drug(8, start="2020-05-01", record_type=999)
    drug(9, concept=201)  # same-day opposite arm
    db.execute("UPDATE cdm.person SET year_of_birth=2010 WHERE person_id=10")
    db.execute("UPDATE cdm.observation_period SET observation_period_start_date='2020-05-01' WHERE person_id=11")
    # Acute episodes: post-start indication must fail; preceding ER visit moves cutoff.
    db.execute("UPDATE cdm.visit_occurrence SET visit_concept_id=9201, visit_start_date='2020-03-01' WHERE person_id=12")
    db.execute("UPDATE cdm.visit_occurrence SET visit_concept_id=9201, visit_start_date='2020-06-01', preceding_visit_occurrence_id=999 WHERE person_id=13")
    db.execute("INSERT INTO cdm.visit_occurrence VALUES (999,13,1,9203,'2020-05-30','2020-06-01',NULL)")
    db.execute("INSERT INTO cdm.measurement VALUES (13,610,'2020-05-31',?), (13,611,'2020-05-29',?)", [visits[13, 1]] * 2)
    for row in [(100, "target", "Ingredient", "RxNorm", "100", "Drug", "S"),
                (200, "comparator", "Ingredient", "RxNorm", "200", "Drug", "S"),
                (500, "indication", "Clinical Finding", "SNOMED", "500", "Condition", "S"),
                (10000, "Oral Tablet", "Dose Form", "RxNorm", "oral", "Drug", "S")]:
        db.execute("INSERT INTO cdm.concept VALUES (?,?,?,?,?,?,?)", row)
    db.executemany("INSERT INTO cdm.concept_ancestor VALUES (?,?)", [(100,100),(100,101),(200,200),(200,201),(500,500)])
    db.executemany("INSERT INTO cdm.drug_strength VALUES (?,?)", [(101,100),(201,200)])
    db.executemany("INSERT INTO cdm.concept_relationship VALUES (?,10000,'RxNorm has dose form',NULL)", [(101,),(201,)])
    return db


def prepare(site):
    db = fixture()
    execute(db, render("SitePartition.sql", care_site_id=site))
    execute(db, render("StudyConcepts.sql", ingredient_rows="(1,100),(0,200),(-1,100),(-1,200)", atc_rows="(1,'')"))
    return db


def run_tests(clinical):
    persons = []
    for site, expected in [(1, {1,5,8,9,10,11,12,13}), (2, {2}), (3, {3})]:
        db = prepare(site)
        observed = {x[0] for x in db.execute("SELECT person_id FROM fps_person").fetchall()}
        assert observed == expected, (site, observed)
        persons.append(observed)
        execute(db, render("DefaultStudy.sql"))
        if site == 1:
            assert str(db.execute("SELECT MIN(cohort_start_date) FROM fps_exposure WHERE subject_id=1").fetchone()[0]) == "2020-06-01"
            assert str(db.execute("SELECT MIN(cohort_start_date) FROM fps_exposure WHERE subject_id=5").fetchone()[0]) == "2020-06-01"
        # Known cohort rows at the boundary to the upstream CohortMethod extractor.
        # CohortMethod itself is not replaced or claimed to be integration-tested here.
        db.execute("CREATE TEMP TABLE cohort_person AS SELECT ROW_NUMBER() OVER (ORDER BY subject_id) row_id, * EXCLUDE(covariate_cutoff) FROM fps_exposure QUALIFY ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY cohort_start_date,cohort_definition_id)=1")
        execute(db, render("Covariates.sql", clinical_sql=clinical["default"]))
        if site == 1:
            features = {r[0] for r in db.execute("SELECT f.covariate_id FROM fps_covariates f JOIN cohort_person c USING(row_id) WHERE c.subject_id=1").fetchall()}
            assert 600401 in features and 700301 in features and 300201 in features
            assert not features.intersection({601401,602401,603401,605401,606401,101201,201201})
            assert db.execute("SELECT COUNT(*) FROM fps_covariates WHERE covariate_id=600401").fetchone()[0] == 1
            assert db.execute("SELECT COUNT(*) FROM fps_covariates WHERE covariate_id=604401").fetchone()[0] == 0
        db.close()
    assert not (persons[0] & persons[1] or persons[1] & persons[2] or persons[0] & persons[2])
    db = prepare(1)
    execute(db, render("SpecificStudy.sql", form_policy="oral_single", record_type_concept_ids="32818",
        min_age=18, prior_days=365, indication_days=180, washout_days=180, indication_concept_ids="500"))
    eligible = {r[0] for r in db.execute("SELECT subject_id FROM fps_exposure").fetchall()}
    assert eligible == {1,5,13}, eligible
    assert str(db.execute("SELECT covariate_cutoff FROM fps_exposure WHERE subject_id=13").fetchone()[0]) == "2020-05-30"
    db.execute("CREATE TEMP TABLE cohort_person AS SELECT ROW_NUMBER() OVER (ORDER BY subject_id) row_id, * EXCLUDE(covariate_cutoff) FROM fps_exposure")
    execute(db, render("Covariates.sql", clinical_sql=clinical["studySpecific"]))
    assert db.execute("SELECT COUNT(*) FROM fps_covariates WHERE covariate_id IN (610401,610402)").fetchone()[0] == 0
    assert db.execute("SELECT COUNT(*) FROM fps_covariates WHERE covariate_id IN (611401,611402)").fetchone()[0] == 2
    db.close()
    print("PASS: three disjoint institutions; missing/mismatched visits; site-local exposures and binary features; washout, age, observation, concurrent arms and acute cutoff")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--r", default="Rscript")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        for scenario in ("default", "studySpecific"):
            path = str(Path(tmp, scenario + ".sql"))
            code = 'source("R/StudySettings.R"); source("R/CareSiteData.R"); writeLines(.careSiteClinicalSql("cdm", getStudySettings("ppi", %s)), %s)' % (json.dumps(scenario), json.dumps(path))
            subprocess.run([args.r, "--vanilla", "-e", code], cwd=ROOT, check=True, capture_output=True)
        run_tests({s: Path(tmp, s + ".sql").read_text() for s in ("default", "studySpecific")})
