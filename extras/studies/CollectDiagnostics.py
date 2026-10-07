#!/usr/bin/env python3
"""Collect cohort attrition and feature overlap; never fit models or match patients.

uv run --with 'psycopg[binary]' --with python-dotenv python extras/studies/CollectDiagnostics.py
Only aggregate CSV/JSON files are written locally. Study-specific clinical
readiness is a separate review from successful execution and nonzero counts.
"""
import argparse
import csv
import itertools
import json
from pathlib import Path
import psycopg
from psycopg import sql
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "output/studies"


def write_csv(path, rows):
    if not rows: return
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--features-only", action="store_true", help="Refresh local feature/timing summaries without querying cohort counts again")
    args = parser.parse_args()
    registry = json.loads((ROOT/"inst/studies/registry.json").read_text())
    counts, inclusion, overlap, timing = [], [], [], []
    for source in ([] if args.features_only else ["mimic", "synpuf"]):
        c = dotenv_values(ROOT / f".Renviron.{source}")
        schema, results = c["CDM_DATABASE_SCHEMA"], "fps_studies_"+source
        with psycopg.connect(host=c["PGHOST"],port=c["PGPORT"],dbname=c["PGDATABASE"],user=c["PGUSER"],password=c["PGPASSWORD"],
                             options="-c default_transaction_read_only=on") as con:
            if source == "synpuf":
                partition=[]
                for mode,field in [("caseMix","site_id"),("random","random_site_id")]:
                    records=con.execute(sql.SQL("SELECT {},count(*),avg(age),avg(charlson),avg(visits),min(probability_a),max(probability_a) FROM fps_sim.site_membership GROUP BY 1 ORDER BY 1").format(sql.Identifier(field))).fetchall()
                    for row in records:
                        partition.append(dict(mode=mode,**dict(zip(["site","persons","meanAge","meanCharlson","meanVisits","minCaseProbabilityA","maxCaseProbabilityA"],row))))
                write_csv(OUT/"partition_diagnostics.csv",partition)
                record=con.execute("SELECT count(*) AS persons,count(DISTINCT person_id) AS unique_persons,count(*) FILTER(WHERE site_id NOT IN ('synpufA','synpufB') OR site_id IS NULL) AS invalid_assignment FROM fps_sim.site_membership").fetchone()
                write_csv(OUT/"partition_integrity.csv",[dict(persons=record[0],uniquePersons=record[1],duplicatePersons=record[0]-record[1],invalidAssignments=record[2])])
            for study in registry:
                for scenario in ["default", "studySpecific"]:
                    marker = OUT/source/study["study"]/scenario/"cohorts.json"
                    if not marker.exists() or json.loads(marker.read_text())["status"] != "complete": continue
                    offset = 100000 if scenario == "default" else 0
                    ids = [study["targetId"]+offset,study["comparatorId"]+offset]
                    if source == "mimic":
                        sites = [("mimic", None, None)]
                    else:
                        sites = [("synpuf",None,None),("synpufA","site_id","synpufA"),
                            ("synpufB","site_id","synpufB"),("synpufA_random","random_site_id","synpufA"),
                            ("synpufB_random","random_site_id","synpufB")]
                    for site, field, membership in sites:
                        join = sql.SQL("") if not field else sql.SQL("JOIN fps_sim.site_membership m ON m.person_id=c.subject_id AND m.{}={}").format(sql.Identifier(field),sql.Literal(membership))
                        landmark = sql.SQL("TRUE") if not field else sql.SQL("c.cohort_start_date>=m.landmark_date")
                        age_filter = sql.SQL("") if scenario != 'default' else sql.SQL("""AND EXISTS (
                            SELECT 1 FROM {s}.person p WHERE p.person_id=c.subject_id AND
                            (c.cohort_start_date-TO_DATE(TO_CHAR(p.year_of_birth,'0000')||'-'||
                              TO_CHAR(COALESCE(p.month_of_birth,1),'00')||'-'||TO_CHAR(COALESCE(p.day_of_birth,1),'00'),
                              'YYYY-MM-DD'))/365.25>=18)""").format(s=sql.Identifier(schema))
                        query = sql.SQL("""WITH raw AS (
                          SELECT DISTINCT c.*, {landmark} AS eligible FROM {r}.fps_cohort c {join}
                          WHERE cohort_definition_id=ANY(%s)),
                        eligible AS (SELECT * FROM raw WHERE eligible),
                        untied AS (SELECT c.* FROM eligible c WHERE NOT EXISTS (
                          SELECT 1 FROM eligible d WHERE d.subject_id=c.subject_id
                          AND d.cohort_start_date=c.cohort_start_date AND d.cohort_definition_id<>c.cohort_definition_id)),
                        first_index AS (SELECT *,row_number() OVER (PARTITION BY subject_id ORDER BY cohort_start_date,cohort_definition_id) rn FROM untied),
                        final AS (SELECT * FROM first_index c WHERE rn=1 AND EXISTS (
                          SELECT 1 FROM {s}.observation_period o WHERE o.person_id=c.subject_id
                          AND c.cohort_start_date BETWEEN o.observation_period_start_date AND o.observation_period_end_date) {age_filter}),
                        stages AS (SELECT 'public_cohort' stage,cohort_definition_id,subject_id FROM raw
                          UNION ALL SELECT 'after_site_landmark',cohort_definition_id,subject_id FROM eligible
                          UNION ALL SELECT 'after_same_day_ties',cohort_definition_id,subject_id FROM untied
                          UNION ALL SELECT 'one_person_native_op',cohort_definition_id,subject_id FROM final)
                        SELECT stage,cohort_definition_id,count(DISTINCT subject_id),count(*) FROM stages GROUP BY 1,2""").format(
                            r=sql.Identifier(results),s=sql.Identifier(schema),join=join,landmark=landmark,age_filter=age_filter)
                        rows = con.execute(query,(ids,)).fetchall()
                        lookup={(r[0],r[1]):r[2:] for r in rows}
                        for stage in ["public_cohort","after_site_landmark","after_same_day_ties","one_person_native_op"]:
                            nt,et=lookup.get((stage,ids[0]),(0,0));nc,ec=lookup.get((stage,ids[1]),(0,0))
                            counts.append(dict(study=study["study"],scenario=scenario,site=site,stage=stage,
                                targetPersons=nt,comparatorPersons=nc,targetExposures=et,comparatorExposures=ec,
                                totalPersons=nt+nc if stage=="one_person_native_op" else "",
                                minimumArmPersons=min(nt,nc)))
            # CG inclusion statistics are aggregate diagnostics, not patient rows.
            for table in ["fps_cohort_inclusion", "fps_cohort_inclusion_stats", "fps_cohort_summary_stats"]:
                cur=con.execute(sql.SQL("SELECT * FROM {}.{}").format(sql.Identifier(results),sql.Identifier(table)))
                names=[d.name for d in cur.description]
                write_csv(OUT/f"{source}_{table}.csv",[dict(zip(names,row)) for row in cur.fetchall()])
    if not args.features_only: write_csv(OUT/"cohort_counts.csv", counts)
    for study in registry:
        for scenario in ["default","studySpecific"]:
            features={}
            domains={}
            for site in ["mimic","synpufA","synpufB"]:
                directory=OUT/site/study["study"]/scenario
                marker=directory/"features.json"
                if not marker.exists() or json.loads(marker.read_text())["status"]!="complete": continue
                with (directory/"covariates.csv").open() as stream:
                    rows=list(csv.DictReader(stream))
                features[site]={r["covariateId"] for r in rows if int(r["targetCount"])+int(r["comparatorCount"])>0}
                domains[site]={domain:{r["covariateId"] for r in rows if r['domainId']==domain and int(r['targetCount'])+int(r['comparatorCount'])>0}
                               for domain in {r['domainId'] for r in rows}}
            for n in [2,3]:
                for sites in itertools.combinations(features,n):
                    for domain in ['All']+sorted({'Demographics','Condition','Drug','Procedure','Measurement'} | set.union(*(set(domains[s]) for s in sites))):
                        values=[features[s] if domain=='All' else domains[s].get(domain,set()) for s in sites]
                        union=set.union(*values); shared=set.intersection(*values)
                        overlap.append(dict(study=study["study"],scenario=scenario,sites="+".join(sites),domain=domain,
                            unionFeatures=len(union),sharedFeatures=len(shared),jaccard=len(shared)/len(union) if union else None,
                            siteFeatureCounts=';'.join(f'{s}:{len(v)}' for s,v in zip(sites,values)),
                            zeroCaptureSite=any(not v for v in values),completeThreeSiteComparison=len(features)==3))
    write_csv(OUT/"feature_overlap.csv",overlap)
    for marker in OUT.glob("*/*/*/*.json"):
        if marker.name not in ["cohorts.json","features.json"]: continue
        row=json.loads(marker.read_text())
        timing.append({key:row.get(key,"") for key in ["site","study","scenario","status","seconds","mode","sharedBatch","runtimeScope","definitionHash","error"]}|{"phase":marker.stem})
    write_csv(OUT/"preparation_times.csv",timing)
    print(f"Saved {len(counts)} cohort-stage rows, {len(overlap)} overlap comparisons, {len(timing)} stage timings.")


if __name__=="__main__": main()
