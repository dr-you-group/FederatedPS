"""Exercise portable CTE sampling semantics in SQLite, not SQL Server integration."""
from pathlib import Path
import sqlite3, re
sql=Path('inst/sql/sql_server/LimitPatients.sql').read_text()
selection=sql[sql.index(';WITH'):sql.index('CREATE UNIQUE')]
selection=selection.replace('#fps_exposure','exposure').replace('SELECT TOP (@patient_limit) subject_id INTO #fps_limited_person','SELECT subject_id')
selection=selection.rstrip().removesuffix(';')+' LIMIT ?'
con=sqlite3.connect(':memory:')
con.execute('CREATE TABLE exposure(subject_id INTEGER, cohort_definition_id INTEGER, cohort_start_date TEXT)')
rows=[(p,1 if p<=7 else 2,'2020-01-01') for p in range(1,11)]
# Crossovers and ties: select each patient once, leave all exposures for them.
rows += [(1,2,'2020-02-01'),(2,2,'2020-01-01'),(8,2,'2020-03-01')]
con.executemany('INSERT INTO exposure VALUES(?,?,?)',rows)
for limit in [2,3,4,8,200]:
    got=[r[0] for r in con.execute(selection,(limit,))]
    assert len(got)==min(limit,10) and len(set(got))==len(got)
    assert got==[1,8,2,9,3,10,4,5,6,7][:limit]
    retained=[row for row in rows if row[0] in got]
    for p in got: assert [r for r in retained if r[0]==p]==[r for r in rows if r[0]==p]
    con.execute('DELETE FROM exposure')
    con.executemany('INSERT INTO exposure VALUES(?,?,?)',reversed(rows))
    assert got==[r[0] for r in con.execute(selection,(limit,))]
assert re.search(r'DELETE e FROM #fps_exposure e\s+WHERE NOT EXISTS',sql)
print('PASS: SQL sampling CTE semantics, distinct-person cap, arm interleaving, crossovers/ties, deterministic ordering; SQLite dialect adaptation only')
