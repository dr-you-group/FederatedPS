#!/usr/bin/env python3
"""Register a CDM vocabulary in the dedicated local ATLAS metadata database.

uv run --with 'psycopg[binary]' --with python-dotenv python extras/studies/RegisterAtlasVocabulary.py
Only the Vocabulary daimon is registered. Cohort preparation runs through the R
runner; this UI connection does not expose patient profiles or generate cohorts.
"""
from pathlib import Path
import subprocess
from urllib.parse import quote
from dotenv import dotenv_values
from psycopg import sql

root = Path(__file__).resolve().parents[2]
c = dotenv_values(root / ".Renviron.mimic")
jdbc = (f"jdbc:postgresql://{c['PGHOST']}:{c['PGPORT']}/{quote(c['PGDATABASE'],safe='')}"
        f"?user={quote(c['PGUSER'],safe='')}&password={quote(c['PGPASSWORD'],safe='')}")
statement = sql.SQL("""BEGIN;
INSERT INTO webapi.source(source_id, source_name, source_key, source_connection, source_dialect)
SELECT coalesce(max(source_id),0)+1, 'FederatedPS reference vocabulary', 'FPS_VOCAB', {jdbc}, 'postgresql'
FROM webapi.source WHERE NOT EXISTS (SELECT 1 FROM webapi.source WHERE source_key='FPS_VOCAB')
HAVING NOT EXISTS (SELECT 1 FROM webapi.source WHERE source_key='FPS_VOCAB');
INSERT INTO webapi.source_daimon(source_daimon_id,source_id,daimon_type,table_qualifier,priority)
SELECT (SELECT coalesce(max(source_daimon_id),0)+1 FROM webapi.source_daimon), source_id, 1, {schema}, 10
FROM webapi.source s WHERE source_key='FPS_VOCAB' AND NOT EXISTS (
 SELECT 1 FROM webapi.source_daimon d WHERE d.source_id=s.source_id AND d.daimon_type=1);
COMMIT;
""").format(jdbc=sql.Literal(jdbc),schema=sql.Literal(c["CDM_DATABASE_SCHEMA"])).as_string()
result = subprocess.run(["docker", "compose", "--env-file", str(root/".env.atlas"), "-p", "federatedps-atlas",
    "-f",str(root/"atlas/compose.yaml"), "exec", "-T", "atlasdb", "psql", "-U", "webapi", "-d", "ohdsi", "-v", "ON_ERROR_STOP=1"],
    input=statement,text=True,capture_output=True)
if result.returncode:
    # SQL error contexts can contain the JDBC password; do not echo them.
    raise SystemExit("Vocabulary registration failed; inspect local metadata schema without printing connection strings.")
print("Local reference vocabulary registered. Restart WebAPI to refresh source metadata.")
