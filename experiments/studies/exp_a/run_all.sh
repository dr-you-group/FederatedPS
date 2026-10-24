#!/bin/bash
# Out-of-fold local / pooled analysis on the three large sites for the given studies (default: all).
# Run studies/data/run_extract.sh first.
set -u
. "$(dirname "$0")/../../common/env.sh"
LOG=$FP_OUT/logs/analyze.log
for study in ${@:-$STUDIES}; do
  if [ -f "$FP_DATA/design/${study}__mimiciv.rds" ] && [ -f "$FP_DATA/design/${study}__synpuf.rds" ]; then
    echo "=== $(date +%H:%M:%S) $study ===" >> "$LOG"
    $RSCRIPT "$FP_EXP/studies/exp_a/analyze.R" "$study" 2>&1 | tail -40 >> "$LOG"
  else
    echo "!!! $study: design files missing, skipped" >> "$LOG"
  fi
done
echo "=== $(date +%H:%M:%S) done ===" >> "$LOG"
