#!/bin/bash
# Extract the MIMIC and SynPUF designs for the given studies (default: all), one at a time.
# Needs PGPASSWORD and the FP_DB_* settings read by extract.R.
set -u
. "$(dirname "$0")/../../common/env.sh"
LOG=$FP_OUT/logs/extract.log
for study in ${@:-$STUDIES}; do
  for schema in mimiciv synpuf; do
    echo "=== $(date +%H:%M:%S) $study / $schema ===" >> "$LOG"
    $RSCRIPT "$FP_EXP/studies/data/extract.R" "$study" "$schema" 2>&1 | grep -v -E '^\s*\|' | tail -3 >> "$LOG"
  done
done
echo "=== $(date +%H:%M:%S) done ===" >> "$LOG"
