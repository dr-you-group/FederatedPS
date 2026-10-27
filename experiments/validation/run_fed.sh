#!/bin/bash
# Multi-process federation over the file exchange: one aggregator and one process per site.
# run_fed.sh <scenario> <runId> <P> <alpha> <site...>
# Site data: $FP_OUT/sitedata/<scenario>/<site>.rds; results: $FP_OUT/fedruns/<runId>.
set -e
. "$(dirname "$0")/../common/env.sh"
SCEN=$1; RUN=$2; P=$3; ALPHA=$4; shift 4; SITES="$@"
V=$FP_EXP/validation
EX=$FP_EXCHANGE/$RUN; rm -rf "$EX"; mkdir -p "$EX"
OUT=$FP_OUT/fedruns/$RUN; rm -rf "$OUT"; mkdir -p "$OUT"
pkill -f "janitor.sh .* $RUN\$" 2>/dev/null || true; sleep 1
"$V/janitor.sh" "$EX" "$RUN" 30000 & JAN=$!
$RSCRIPT "$V/agg_driver.R" "$EX" "$RUN" "$OUT/agg.rds" $SITES > "$OUT/agg.log" 2>&1 &
AGG=$!
for s in $SITES; do
  $RSCRIPT "$V/site_driver.R" "$s" "$EX" "$RUN" "$FP_OUT/sitedata/$SCEN/$s.rds" "$P" "$ALPHA" "$OUT/$s.rds" \
    > "$OUT/$s.log" 2>&1 &
done
AGGRC=0; wait $AGG || AGGRC=$?
kill $JAN 2>/dev/null || true
if [ $AGGRC -ne 0 ]; then
  echo "aggregator failed (rc=$AGGRC)"; pkill -f "site_driver.R .* $RUN " 2>/dev/null || true
  cat "$OUT/agg.log"; rm -rf "$EX"; exit $AGGRC
fi
for s in $SITES; do
  for i in $(seq 1 600); do [ -f "$OUT/$s.rds" ] && break; sleep 0.5; done
done
sleep 1
rm -rf "$EX"
echo "--- $RUN finished ---"
tail -n 2 "$OUT"/*.log
