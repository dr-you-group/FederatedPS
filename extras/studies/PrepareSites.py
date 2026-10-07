#!/usr/bin/env python3
"""Create disjoint SynPUF virtual sites, retaining complete patient histories.

uv run --with 'psycopg[binary]' --with python-dotenv python extras/studies/PrepareSites.py
No source CDM tables are modified. Reuse an existing partition only if its
configuration hash agrees; a changed rule requires a new analysis schema.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path

import psycopg
from psycopg import sql
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[2]
# Romano categories and weights in FeatureExtraction 3.14.0 CharlsonIndex.sql.
# Restriction to the first 365 observed days is specific to this simulation.
CHARLSON = [([4329847], 1), ([316139], 1), ([321052], 1), ([381591, 434056], 1),
    ([4182210], 1), ([4063381], 1), ([257628, 134442, 80800, 80809, 256197, 255348], 1),
    ([4247120], 1), ([4064161, 4212540], 1), ([201820], 1), ([443767, 442793], 2),
    ([192606, 374022], 2), ([4030518], 2), ([443392], 2),
    ([4245975, 4029488, 192680, 24966], 3), ([432851], 6), ([439727], 6)]
SHARED = {"concept", "concept_ancestor", "concept_relationship", "concept_synonym", "concept_class",
          "vocabulary", "domain", "relationship", "drug_strength", "source_to_concept_map",
          "cdm_source", "metadata", "care_site", "provider", "location"}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--connection-file", default=".Renviron.synpuf")
    p.add_argument("--analysis-schema", default="fps_sim")
    p.add_argument("--seed", type=int, default=20261007)
    p.add_argument("--output", default="output/studies/partition.json")
    args = p.parse_args()
    config = dotenv_values(ROOT / args.connection_file)
    source = config["CDM_DATABASE_SCHEMA"]
    schema = args.analysis_schema
    if schema == source or schema in SHARED: raise ValueError("Use a separate analysis schema")
    spec = dict(version=1, source=source, seed=args.seed, baselineDays=365, minimumAge=18,
        predictors=["age", "Romano Charlson categories", "log1p baseline visit count"],
        standardization="population mean and population SD; equal weights",
        probability="0.2 + 0.6 * logistic(intercept + score); mean calibrated to 0.5",
        assignment="first 52 bits of MD5(seed:case:person_id), divided by 2^52",
        randomControl="independent MD5(seed:random:person_id) < 0.5",
        landmark="start of first native observation period lasting at least 365 days + 365 days",
        charlson=CHARLSON)
    digest = hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()
    started = time.monotonic()
    with psycopg.connect(host=config["PGHOST"], port=config["PGPORT"], dbname=config["PGDATABASE"],
                         user=config["PGUSER"], password=config["PGPASSWORD"]) as con:
        cur = con.cursor()
        def run(query, **identifiers):
            return cur.execute(sql.SQL(query).format(s=sql.Identifier(source), a=sql.Identifier(schema),
                **{k: sql.Identifier(v) for k, v in identifiers.items()}))
        run("CREATE SCHEMA IF NOT EXISTS {a}")
        run("CREATE TABLE IF NOT EXISTS {a}.partition_config (singleton boolean PRIMARY KEY DEFAULT TRUE CHECK(singleton), hash text NOT NULL, specification jsonb NOT NULL)")
        old = run("SELECT hash FROM {a}.partition_config").fetchone()
        if old and old[0] != digest: raise ValueError("Existing partition differs; use a new analysis schema")
        if not old:
            print("Preparing landmark population and baseline case mix", flush=True)
            run("""CREATE TABLE {a}.site_membership AS
                WITH periods AS (
                  SELECT *, row_number() OVER (PARTITION BY person_id ORDER BY observation_period_start_date,
                      observation_period_end_date, observation_period_id) AS rn
                  FROM {s}.observation_period
                  WHERE observation_period_end_date >= observation_period_start_date + 365)
                SELECT p.person_id, o.observation_period_start_date AS baseline_start,
                    o.observation_period_start_date + 365 AS landmark_date,
                    extract(year FROM age(o.observation_period_start_date + 365,
                      make_date(p.year_of_birth, coalesce(p.month_of_birth,1), coalesce(p.day_of_birth,1))))::int AS age
                FROM periods o JOIN {s}.person p USING(person_id) WHERE rn=1""")
            run("DELETE FROM {a}.site_membership WHERE age < 18 OR age IS NULL")
            run("ALTER TABLE {a}.site_membership ADD PRIMARY KEY(person_id)")
            rows = [(i, root, weight) for i, (roots, weight) in enumerate(CHARLSON, 1) for root in roots]
            cur.execute("CREATE TEMP TABLE fps_charlson_roots(category int, concept_id int, weight int)")
            cur.executemany("INSERT INTO fps_charlson_roots VALUES (%s,%s,%s)", rows)
            run("""CREATE TEMP TABLE fps_charlson AS SELECT r.category, r.weight, ca.descendant_concept_id AS concept_id
                   FROM fps_charlson_roots r JOIN {s}.concept_ancestor ca ON ca.ancestor_concept_id=r.concept_id
                   UNION SELECT category, weight, concept_id FROM fps_charlson_roots""")
            cur.execute("CREATE INDEX ON fps_charlson(concept_id)")
            run("""CREATE TEMP TABLE fps_scores AS SELECT person_id, sum(weight)::int AS charlson FROM (
                   SELECT DISTINCT m.person_id, c.category, c.weight FROM {a}.site_membership m
                   JOIN {s}.condition_era e ON m.person_id=e.person_id
                     AND e.condition_era_start_date >= m.baseline_start AND e.condition_era_start_date < m.landmark_date
                   JOIN fps_charlson c ON c.concept_id=e.condition_concept_id) q GROUP BY person_id""")
            run("""CREATE TEMP TABLE fps_visits AS SELECT m.person_id, count(*)::int AS visits
                   FROM {a}.site_membership m JOIN {s}.visit_occurrence v ON m.person_id=v.person_id
                   AND v.visit_start_date >= m.baseline_start AND v.visit_start_date < m.landmark_date GROUP BY m.person_id""")
            run("ALTER TABLE {a}.site_membership ADD charlson integer NOT NULL DEFAULT 0, ADD visits integer NOT NULL DEFAULT 0, ADD score double precision, ADD probability_a double precision, ADD site_id text, ADD random_site_id text")
            run("UPDATE {a}.site_membership m SET charlson=s.charlson FROM fps_scores s WHERE m.person_id=s.person_id")
            run("UPDATE {a}.site_membership m SET visits=v.visits FROM fps_visits v WHERE m.person_id=v.person_id")
            run("""WITH stats AS (SELECT avg(age) ma, stddev_pop(age) sa, avg(charlson) mc,
                   stddev_pop(charlson) sc, avg(ln(1+visits)) mv, stddev_pop(ln(1+visits)) sv FROM {a}.site_membership)
                   UPDATE {a}.site_membership SET score=(coalesce((age-ma)/nullif(sa,0),0)+
                     coalesce((charlson-mc)/nullif(sc,0),0)+coalesce((ln(1+visits)-mv)/nullif(sv,0),0))/3 FROM stats""")
            lo, hi = -40., 40.
            for _ in range(32):
                mid = (lo + hi) / 2
                cur.execute(sql.SQL("SELECT avg(0.2+0.6/(1+exp(-greatest(-700,least(700,%s+score))))) FROM {}.site_membership").format(sql.Identifier(schema)), (mid,))
                if cur.fetchone()[0] < 0.5: lo = mid
                else: hi = mid
            intercept = (lo+hi)/2
            cur.execute(sql.SQL("UPDATE {}.site_membership SET probability_a=0.2+0.6/(1+exp(-greatest(-700,least(700,%s+score))))").format(sql.Identifier(schema)), (intercept,))
            cur.execute(sql.SQL("""UPDATE {}.site_membership SET
                site_id=CASE WHEN ('x'||substr(md5(%s||':case:'||person_id),1,13))::bit(52)::bigint/4503599627370496.0 < probability_a THEN 'synpufA' ELSE 'synpufB' END,
                random_site_id=CASE WHEN ('x'||substr(md5(%s||':random:'||person_id),1,13))::bit(52)::bigint/4503599627370496.0 < 0.5 THEN 'synpufA' ELSE 'synpufB' END""").format(sql.Identifier(schema)), (str(args.seed),str(args.seed)))
            run("CREATE INDEX ON {a}.site_membership(site_id,person_id)")
            run("CREATE INDEX ON {a}.site_membership(random_site_id,person_id)")
            cur.execute(sql.SQL("INSERT INTO {}.partition_config(hash,specification) VALUES (%s,%s)").format(sql.Identifier(schema)), (digest,json.dumps(dict(spec, intercept=intercept))))
            con.commit()
        columns = cur.execute("SELECT table_name,column_name FROM information_schema.columns WHERE table_schema=%s", (source,)).fetchall()
        tables = {}
        for table, column in columns: tables.setdefault(table,set()).add(column)
        for mode, field in [("case", "site_id"), ("random", "random_site_id")]:
            for suffix, site in [("a","synpufA"),("b","synpufB")]:
                view_schema = f"{schema}_{suffix}" + ("_random" if mode == "random" else "")
                run("CREATE SCHEMA IF NOT EXISTS {v}", v=view_schema)
                for table, names in tables.items():
                    if "person_id" in names:
                        statement = sql.SQL("CREATE OR REPLACE VIEW {v}.{t} AS SELECT c.* FROM {s}.{t} c JOIN {a}.site_membership m ON m.person_id=c.person_id AND m.{f}={site}")
                    elif table in SHARED:
                        statement = sql.SQL("CREATE OR REPLACE VIEW {v}.{t} AS SELECT * FROM {s}.{t}")
                    else: continue
                    cur.execute(statement.format(v=sql.Identifier(view_schema), t=sql.Identifier(table), s=sql.Identifier(source),
                        a=sql.Identifier(schema), f=sql.Identifier(field), site=sql.Literal(site)))
                cur.execute(sql.SQL("CREATE OR REPLACE VIEW {}._fps_site_membership AS SELECT * FROM {}.site_membership WHERE {}={}").format(sql.Identifier(view_schema),sql.Identifier(schema),sql.Identifier(field),sql.Literal(site)))
        summary = run("SELECT site_id,count(*),avg(age),avg(charlson),avg(visits),avg(probability_a) FROM {a}.site_membership GROUP BY site_id ORDER BY site_id").fetchall()
        source_n = run("SELECT count(*) FROM {s}.person").fetchone()[0]
        con.commit()
    result = dict(configurationHash=digest, specification=spec, sourcePersons=source_n,
        sites=[dict(zip(["site","persons","meanAge","meanCharlson","meanVisits","meanProbabilityA"], row)) for row in summary],
        seconds=time.monotonic()-started, sourceTablesModified=False)
    output = ROOT / args.output
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,indent=2,default=float)+"\n")
    print(json.dumps(result,indent=2,default=float))


if __name__ == "__main__": main()
