"""Compare the old and study-first pipelines on invented data.

Executes parsed T-SQL SELECT/join/window/filter/delete logic in DuckDB, omitting
index DDL. This proves fixture semantics, not SQL Server timing or live plans.
"""
import importlib.util,random,re
from pathlib import Path
spec=importlib.util.spec_from_file_location('care_sql',Path('tests/test_care_site_sql.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
legacy=Path('windows/tests/fixtures/pre-study-first')

def old_render(name,**params):
    text=(legacy/name).read_text()
    params={'cdm_database_schema':'cdm',**params}
    return re.sub(r'@(\w+)',lambda x:str(params[x[1]]),text)

def prepare(db,site,cap,scenario,old):
    params=dict(ingredient_rows='(1,100),(0,200),(-1,100),(-1,200)',atc_rows="(1,'')")
    if old:
        m.execute(db,old_render('SitePartition.sql',care_site_id=site))
        m.execute(db,old_render('StudyConcepts.sql',**params))
    else:
        m.execute(db,m.render('StudyConcepts.sql',**params))
        m.execute(db,m.render('SitePartition.sql',care_site_id=site))
        if scenario=='default' and cap:
            m.execute(db,m.render('LimitPartitionPatients.sql',patient_limit=cap))
        m.execute(db,m.render('SiteVisits.sql',care_site_id=site))
        m.execute(db,m.render('StudyDrugs.sql'))
    if scenario=='default':m.execute(db,m.render('DefaultStudy.sql'))
    else:m.execute(db,m.render('SpecificStudy.sql',form_policy='oral_single',record_type_concept_ids='32818',
        min_age=18,prior_days=365,indication_days=180,washout_days=180,indication_concept_ids='500'))
    if cap:m.execute(db,m.render('LimitPatients.sql',patient_limit=cap))
    exposures=db.execute('SELECT * FROM fps_exposure ORDER BY ALL').fetchall()
    people={r[0] for r in exposures}
    visits=[r for r in db.execute('SELECT * FROM fps_visit ORDER BY ALL').fetchall() if r[1] in people]
    count=db.execute('SELECT COUNT(*) FROM fps_visit').fetchone()[0]
    prepared=db.execute('SELECT COUNT(*) FROM fps_person').fetchone()[0]
    # Restrict reference drug rows only for comparison, preserving every row
    # including crossover, prior washout, type-ineligible and dose-form history.
    drugs=[r for r in db.execute('SELECT * FROM fps_drug ORDER BY ALL').fetchall() if r[0] in people]
    return (exposures,visits,drugs),count,prepared

def clean(db):
    for (name,) in db.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='main'").fetchall():
        assert name.startswith('fps_'),name
        db.execute('DROP TABLE '+name)

# Adversarial clinical fixture: specific eligibility, washout, acute episodes,
# unknown/mismatched visits, cross-site visits including an unconfigured site.
db=m.fixture();cases=0
for scenario in ['default','studySpecific']:
 for site in [1,2,3]:
  for cap in [0,2,3,200]:
   old,_,_=prepare(db,site,cap,scenario,True);clean(db)
   new,_,n=prepare(db,site,cap,scenario,False);clean(db)
   assert old==new,(scenario,site,cap)
   if scenario=='default' and cap:assert n<=cap
   cases+=1

# Larger randomized visits/drugs; unconfigured institution IDs, ties,
# crossovers, no exposure, missing dates, invalid or mismatched visit links.
rng=random.Random(20261026);visits=[];drugs=[];next_visit=10000
for person in range(1000,3000):
 site=rng.choice([1,2,3,17,99]);own=[]
 for _ in range(rng.randint(1,12)):
  next_visit+=1;own.append(next_visit)
  visits.append((next_visit,person,site,9202,'2020-01-01','2020-12-31',None))
 if rng.random()<0.15:
  next_visit+=1;visits.append((next_visit,person,rng.choice([None,0,-1,1,2,3,17,99]),9202,'2020-01-01','2020-12-31',None))
 for _ in range(rng.randint(0,8)):
  date=rng.choice(['2020-04-01','2020-06-01','2020-06-01',None])
  drugs.append((person,rng.choice([101,201,300]),date,date,rng.choice(own+[None,-1,1]),32818))
# Bulk fixture insertion (values contain only generated integers/ISO dates).
def literal(x):return 'NULL' if x is None else "'"+x+"'" if isinstance(x,str) else str(x)
for table,rows in [('visit_occurrence',visits),('drug_exposure',drugs)]:
 for start in range(0,len(rows),1000):
  db.execute('INSERT INTO cdm.'+table+' VALUES '+','.join('('+','.join(map(literal,r))+')' for r in rows[start:start+1000]))
reductions=[]
for site in [1,2,3,17,99]:
 for cap in [0,2,3,20,200]:
  old,old_count,_=prepare(db,site,cap,'default',True);clean(db)
  new,new_count,n=prepare(db,site,cap,'default',False);clean(db)
  assert old==new,(site,cap)
  if cap:
   assert n<=cap and new_count<=old_count
   reductions.append((old_count,new_count))
  cases+=1
assert any(n<o for o,n in reductions)
print('PASS:',cases,'old/new pipeline comparisons; exact exposures, all retained-person visits/drug history, arm ties/crossovers, arbitrary positive sites, default early-cap equality, studySpecific late cap')
print('Fixture visit materialization at cap=2 (first site):',reductions[0],'; not a SQL Server timing benchmark')
