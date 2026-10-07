#!/usr/bin/env python3
"""Refresh the README public-study catalog from the registry and local aggregates."""
import csv
import json
from datetime import datetime, timezone
from pathlib import Path

root=Path(__file__).resolve().parents[2]
registry=json.loads((root/'inst/studies/registry.json').read_text())
out=root/'output/studies'
lookup={}
if (out/'cohort_counts.csv').exists():
    for row in csv.DictReader((out/'cohort_counts.csv').open()):
        if row['stage']=='one_person_native_op': lookup[(row['study'],row['scenario'],row['site'])]=row
overlap=[]
if (out/'feature_overlap.csv').exists():
    overlap=list(csv.DictReader((out/'feature_overlap.csv').open()))
shared={(r['study'],r['scenario']):r for r in overlap
        if r['sites']=='mimic+synpufA+synpufB' and r['domain']=='All'}

def read_marker(site, study, scenario, phase):
    path=out/site/study/scenario/(phase+'.json')
    return json.loads(path.read_text()) if path.exists() else {}

def write_snapshot(name, rows):
    if not rows: return
    with (root/'docs'/name).open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(rows[0]),lineterminator='\n')
        writer.writeheader();writer.writerows(rows)

snapshot=[]
for s in registry:
    for scenario in ['default','studySpecific']:
        for site in ['mimic','synpufA','synpufB']:
            key=(s['study'],scenario,site)
            count=lookup.get(key,{})
            cohort=read_marker('mimic' if site=='mimic' else 'synpuf',s['study'],scenario,'cohorts')
            feature=read_marker(site,s['study'],scenario,'features')
            metrics={}
            path=out/site/s['study']/scenario/'counts.csv'
            if feature.get('status')=='complete' and path.exists():
                metrics=next(csv.DictReader(path.open()))
                if count and any(int(metrics[k])!=int(count[k]) for k in ['targetPersons','comparatorPersons']):
                    raise ValueError(f'Population count mismatch between cohort and FeatureExtraction summaries: {key}')
            snapshot.append(dict(study=s['study'],scenario=scenario,site=site,
                cohortStatus=cohort.get('status','pending'),featureStatus=feature.get('status','pending'),
                targetPersons=count.get('targetPersons',''),comparatorPersons=count.get('comparatorPersons',''),
                **{k:metrics.get(k,'') for k in ['features','nonzero','maxAbsoluteSmd','meanAbsoluteSmd','abovePointOne']},
                fractionAbovePointOne=(int(metrics['abovePointOne'])/int(metrics['features']) if metrics and int(metrics['features']) else ''),
                definitionHash=cohort.get('definitionHash',''),error=feature.get('error',cohort.get('error',''))))
write_snapshot('study-feasibility.csv',snapshot)
write_snapshot('study-feature-overlap.csv',overlap)
begin='<!-- BEGIN PUBLIC STUDY CATALOG -->'
end='<!-- END PUBLIC STUDY CATALOG -->'
lines=[begin,'## Public OMOP and Phenotype Library tasks (dev)','',
    'The `dev` extension retains 13 legacy presets and adds **18 public-source comparison tasks**.',
    'The primary simulation uses **MIMIC-IV / SynPUF-A / SynPUF-B**.',
    'These are adapted PS benchmarks, not replications of the publications’ effect estimates.',
    'A registry entry is a candidate; successful cohort generation alone does not establish clinical validity.',
    'See the [preparation and ATLAS workflow](docs/study-workflow.md), [registry](inst/studies/registry.json)',
    'and [pinned source manifest](inst/studies/source/manifest.json). No PS fitting or matching is launched by the preparation scripts.','',
    '### Study questions, references and selection reasons','',
    '| Study ID | Target / comparator | Source journal · year · DOI | Original study question / benchmark reason |',
    '|---|---|---|---|']
for s in registry:
    citation=(f"{s['journal']} · {s['publicationYear']} · [{s['doi']}](https://doi.org/{s['doi']})" if s['doi'] else
        'OHDSI Phenotype Library '+ '/'.join(map(str,s['phenotypeIds']))+'; no comparative-paper DOI/journal/year assigned')
    lines.append(f"| `{s['study']}` | {s['target']} / {s['comparator']} | {citation} | {s['question']} {s['rationale']} |")
lines += ['', 'These are 18 treatment comparisons from several source studies, not 18 independent publications.',
    'The default scenario uses adults ≥18, first recorded drug era and −90…−1-day covariates.',
    'Study-specific windows and source modifications are recorded in the registry and executable ATLAS JSON.',
    'The osteoporosis design retains the original female and >45-year restrictions.',
    'All virtual-site analyses additionally require index on/after the first 365-day baseline landmark.',
    'The selected antibiotic phenotypes have pending library peer review and require formulation review.',
    'UTI strict definitions are blocked on the current vocabulary because excluded MedDRA seeds 36102152 and 36102938 are missing.',
    'Other invalid/deprecated seeds are retained transparently for review in the concept audit; a familiar drug name alone does not validate the resolved cohort.','',
    '### Cohort preparation counts','',
    'Values are **Target / Comparator persons before matching**, after pair selection, site landmark and native OP.',
    'V1 = `default`; V2 = `studySpecific`. `pending` means no completed count is available; it is not zero.',
    '`blocked` identifies a failed vocabulary prerequisite. These counts come from cohort-generation diagnostics,',
    'not from a completed local/pooled/federated analysis. The [aggregate snapshot](docs/study-feasibility.csv)',
    'also records feature counts and prematch SMD summaries; local `output/studies/cohort_counts.csv` retains all attrition stages.','',
    'Snapshot refreshed (UTC): '+datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M')+'.','',
    '| Study | V1 MIMIC-IV | V1 SynPUF-A | V1 SynPUF-B | V2 MIMIC-IV | V2 SynPUF-A | V2 SynPUF-B |',
    '|---|---:|---:|---:|---:|---:|---:|']
for s in registry:
    cells=[]
    for scenario in ['default','studySpecific']:
        for site in ['mimic','synpufA','synpufB']:
            r=lookup.get((s['study'],scenario,site))
            cohort=read_marker('mimic' if site=='mimic' else 'synpuf',s['study'],scenario,'cohorts')
            blocked=cohort.get('status')=='failed'
            cells.append('blocked' if blocked else (f"{int(r['targetPersons']):,} / {int(r['comparatorPersons']):,}" if r else 'pending'))
    lines.append('| `'+s['study']+'` | '+' | '.join(cells)+' |')
lines += ['', 'Source-level patients can appear in several studies; do not add counts across rows.',
    'The UTI and pneumonia fluoroquinolone/cephalosporin tasks share the same default exposure definition;',
    'their indication-specific scenario differs. The identical default rows are not independent PS tasks.','',
    '### Observed feature overlap before fitting','',
    'Each cell is **three-site intersection / union of nonzero covariateIds (Jaccard %)**.',
    'The same feature definition and window are required for an ID to count as shared.',
    'These counts do not measure PS overlap, common support or matching retention; those require fitted scores.',
    'See the [domain and site-pair breakdown](docs/study-feature-overlap.csv). A small intersection alone is not',
    'a rejection threshold, and a large intersection does not establish clinical comparability.',
    'In particular, zero measurement capture in a claims source is a recording difference, not an absence of disease.','',
    '| Study | V1 shared / union (Jaccard) | V2 shared / union (Jaccard) |',
    '|---|---:|---:|']
for s in registry:
    cells=[]
    for scenario in ['default','studySpecific']:
        r=shared.get((s['study'],scenario))
        blocked=any(read_marker(site,s['study'],scenario,'cohorts').get('status')=='failed' for site in ['mimic','synpuf'])
        cells.append(f"{int(r['sharedFeatures']):,} / {int(r['unionFeatures']):,} ({float(r['jaccard'])*100:.1f}%)" if r else ('blocked' if blocked else 'pending'))
    lines.append('| `'+s['study']+'` | '+' | '.join(cells)+' |')
lines += ['', 'Individual covariate prevalences and prematch absolute SMDs remain in local `output/studies/<site>/<study>/<scenario>/covariates.csv`.',
    'No local-only / pooled / federated result or postmatch metric is included in this preparation snapshot.','',
    '### Recorded site and ATLAS preparation','']
if (out/'partition.json').exists():
    partition=json.loads((out/'partition.json').read_text())
    eligible=sum(s['persons'] for s in partition['sites'])
    lines += [f"SynPUF partition eligibility: **{eligible:,} persons**; seed {partition['specification']['seed']}.",
        f"The recorded partition preparation took {partition['seconds']:.0f} seconds on this environment.",
        'These are site populations, not per-study N. The two virtual sites share one synthetic data source.']
if (out/'partition_diagnostics.csv').exists():
    lines += ['', '| Partition | Site | Persons | Mean age | Mean Charlson | Mean baseline visits |',
        '|---|---|---:|---:|---:|---:|']
    for r in csv.DictReader((out/'partition_diagnostics.csv').open()):
        label={'synpufA':'SynPUF-A','synpufB':'SynPUF-B'}[r['site']]
        lines.append(f"| {r['mode']} | {label} | {int(r['persons']):,} | {float(r['meanAge']):.2f} | {float(r['meanCharlson']):.2f} | {float(r['meanVisits']):.2f} |")
if (out/'partition_integrity.csv').exists():
    r=next(csv.DictReader((out/'partition_integrity.csv').open()))
    lines += ['', f"Duplicate persons: {r['duplicatePersons']}; invalid assignments: {r['invalidAssignments']}."]
if (out/'atlas_ids.csv').exists():
    atlas=list(csv.DictReader((out/'atlas_ids.csv').open()))
    lines += ['', f"Local ATLAS: {len(atlas)} cohort definitions; {sum(bool(r['conceptReview']) for r in atlas)} entries flag an unresolved concept-set review."]
lines += ['', 'Local-only, pooled and federated fitting times remain unmeasured.',
    'Open `http://localhost:18081/atlas/` and search cohort names beginning with `FPS /`.',
    'The legacy feasibility counts below describe the earlier MIMIC/SynPUF/EHRSHOT setup and are not these new virtual-site results.','',end]
readme=root/'README.md'
text=readme.read_text()
block='\n'.join(lines)+'\n\n'
if begin in text:
    start=text.index(begin);finish=text.index(end,start)+len(end)
    text=text[:start]+block.rstrip()+text[finish:]
else:
    position=text.index('Requirements\n')
    text=text[:position]+block+text[position:]
readme.write_text(text)
print('README public-study catalog refreshed; pending counts are explicit.')
