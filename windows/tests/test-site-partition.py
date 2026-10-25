"""Compare old/new membership semantics on adversarial + randomized visits.

SQLite executes adapted SELECT INTO statements; this is not a SQL Server plan
or timing test. No patient rows leave the fixture.
"""
import itertools
import random
import re
import sqlite3
from pathlib import Path

source = Path('inst/sql/sql_server/SitePartition.sql').read_text()
rng = random.Random(20261026)
rows = []
for person, sites in enumerate(itertools.chain(
        ([None], [0], [-1], [1], [1, 1], [1, 2], [2, 99], [3, None, 0], [17, 17]),
        ([rng.choice([None, -1, 0, 1, 2, 3, 17, 99]) for _ in range(rng.randint(1, 20))]
         for _ in range(1000))), 1):
    for site in sites:
        rows.append((len(rows)+1, person, site, 9201, '2020-01-01', '2020-01-02', None, 'unused'*100))

for site in (1, 2, 3, 17, 99):
    db = sqlite3.connect(':memory:')
    db.execute('CREATE TABLE VISIT_OCCURRENCE (visit_occurrence_id INTEGER, person_id INTEGER, care_site_id INTEGER, visit_concept_id INTEGER, visit_start_date TEXT, visit_end_date TEXT, preceding_visit_occurrence_id INTEGER, unused_wide_column TEXT)')
    db.executemany('INSERT INTO VISIT_OCCURRENCE VALUES (?,?,?,?,?,?,?,?)', rows)
    old = db.execute('SELECT person_id, MIN(care_site_id), COUNT(DISTINCT care_site_id) FROM VISIT_OCCURRENCE WHERE care_site_id > 0 GROUP BY person_id').fetchall()
    expected_people = {p for p, s, n in old if s == site and n == 1}
    expected_multi = sum(n > 1 for p, s, n in old)
    sql = re.sub(r'--[^\n]*', '', source).replace('@cdm_database_schema.', '').replace('@care_site_id', str(site)).replace('#fps_', 'fps_')
    sql = re.sub(r'\bCLUSTERED\s+', '', sql, flags=re.I)
    for statement in sql.split(';'):
        statement = statement.strip()
        if not statement:
            continue
        match = re.search(r'\bINTO\s+(fps_\w+)', statement, re.I)
        if match:
            table = match[1]
            statement = f'CREATE TABLE {table} AS ' + statement[:match.start()] + statement[match.end():]
        db.execute(statement)
    got_people = {r[0] for r in db.execute('SELECT person_id FROM fps_person')}
    got_visits = set(db.execute('SELECT visit_occurrence_id,person_id,visit_concept_id,visit_start_date,visit_end_date,preceding_visit_occurrence_id FROM fps_visit'))
    expected_visits = {(r[0],r[1],r[3],r[4],r[5],r[6]) for r in rows if r[1] in expected_people and r[2] == site}
    assert got_people == expected_people
    assert got_visits == expected_visits
    assert db.execute('SELECT COUNT(*) FROM fps_membership WHERE care_site_id <> last_care_site_id').fetchone()[0] == expected_multi
    assert len(db.execute('PRAGMA table_info(fps_visit)').fetchall()) == 6
    db.close()
print('PASS: MIN/MAX exclusivity equals COUNT DISTINCT; cross-site/null/nonpositive handling, audit count, exact visit rows, six required columns')
