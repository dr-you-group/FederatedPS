#!/usr/bin/env python3
"""Audit every included/excluded seed against each source vocabulary (read-only)."""
import csv
import json
from pathlib import Path
import psycopg
from psycopg import sql
from dotenv import dotenv_values

ROOT=Path(__file__).resolve().parents[2]
out=ROOT/'output/studies'
out.mkdir(parents=True,exist_ok=True)
requests=[]
for path in sorted((ROOT/'inst/studies/cohorts').glob('*/*.json')):
    expression=json.loads(path.read_text())
    scenario,arm=path.stem.rsplit('_',1)
    for cs in expression['ConceptSets']:
        for item in cs['expression']['items']:
            concept=item['concept']
            requests.append(dict(study=path.parent.name,scenario=scenario,arm=arm,codesetId=cs['id'],
                seedId=concept['CONCEPT_ID'],sourceName=concept['CONCEPT_NAME'],
                sourceCode=concept['CONCEPT_CODE'],sourceDomain=concept['DOMAIN_ID'],
                excluded=item.get('isExcluded',False),descendants=item.get('includeDescendants',False)))
rows=[]
for site in ['mimic','synpuf']:
    c=dotenv_values(ROOT/f'.Renviron.{site}')
    with psycopg.connect(host=c['PGHOST'],port=c['PGPORT'],dbname=c['PGDATABASE'],user=c['PGUSER'],password=c['PGPASSWORD'],
                         options='-c default_transaction_read_only=on') as con:
        records=con.execute(sql.SQL('SELECT concept_id,concept_name,concept_code,domain_id,standard_concept,invalid_reason FROM {}.concept WHERE concept_id=ANY(%s)').format(sql.Identifier(c['CDM_DATABASE_SCHEMA'])),(list({r['seedId'] for r in requests}),)).fetchall()
        lookup={r[0]:r[1:] for r in records}
        for request in requests:
            value=lookup.get(request['seedId'])
            status='missing' if value is None else ('invalid' if value[4] else ('code_or_domain_changed' if value[1]!=request['sourceCode'] or value[2]!=request['sourceDomain'] else 'present'))
            rows.append(dict(site=site,**request,status=status,currentName=value[0] if value else '',standardConcept=value[3] if value else ''))
with (out/'concept_seed_audit.csv').open('w',newline='') as stream:
    writer=csv.DictWriter(stream,fieldnames=rows[0].keys());writer.writeheader();writer.writerows(rows)
for site in ['mimic','synpuf']:
    issues={(r['seedId'],r['status']) for r in rows if r['site']==site and r['status']!='present'}
    print(site,'unique seed issues:',sorted(issues))
