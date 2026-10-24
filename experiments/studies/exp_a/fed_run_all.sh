#!/bin/bash
# Multi-process federated runs (block CCD, P = 50) for every (study, fold); finished runs are skipped.
# Run fed_prep_all.sh first.
set -u
. "$(dirname "$0")/../../common/env.sh"
LOG=$FP_OUT/logs/fed_run.log; JOBFILE=$FP_OUT/fedjobs.txt; ALPHA=$FP_OUT/fedalpha.csv
mkdir -p "$FP_OUT/logs/fed"
[ -f "$ALPHA" ] || $RSCRIPT "$FP_EXP/studies/exp_a/fed_alpha.R" $STUDIES > "$ALPHA"
: > "$JOBFILE"
while IFS=, read -r study alpha rest; do
  [ "$study" = "study" ] && continue
  for f in 1 2 3 4 5; do
    echo "$study $f $alpha fed$(echo -n "${study}${f}" | md5sum | cut -c1-12)" >> "$JOBFILE"
  done
done < "$ALPHA"
echo "jobs: $(wc -l < "$JOBFILE")" >> "$LOG"
run_one() {
  set -- $1; study=$1; f=$2; alpha=$3; rid=$4
  out=$FP_OUT/fedruns/$rid
  if [ -f "$out/synpufB.rds" ] && [ -f "$out/agg.rds" ]; then echo "skip $study f$f" >> "$LOG"; return 0; fi
  s=$(date +%s)
  if "$FP_EXP/validation/run_fed.sh" "fed_${study}_f${f}" "$rid" 50 "$alpha" synpufA mimic synpufB \
       > "$FP_OUT/logs/fed/${study}_f${f}.log" 2>&1; then
    echo "done $study f$f  $(( ($(date +%s) - s) / 60 )) min" >> "$LOG"
  else
    echo "failed $study f$f" >> "$LOG"
  fi
}
export -f run_one; export LOG
xargs -P "$JOBS" -I{} bash -c 'run_one "{}"' < "$JOBFILE"
echo "=== all runs finished $(date +%H:%M:%S) ===" >> "$LOG"
