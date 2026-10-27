#!/bin/bash
# Plasmode runs for every study x partner setting {homo, cluster, synpuf}. Pass "cv" for CV-tuned variances.
set -u
. "$(dirname "$0")/../../common/env.sh"
CV=${1:-}; SUF=${CV:+_cv}
LOG=$FP_OUT/logs/plasmode_cons$SUF.log; : > "$LOG"
for s in $STUDIES; do for st in homo cluster synpuf; do echo "$s $st"; done; done |
xargs -P "$JOBS" -I{} sh -c 'set -- {}; [ -f "$FP_OUT/plasmode_cons'"$SUF"'/$1__$2.csv" ] && exit 0
  $RSCRIPT "$FP_EXP/studies/effect/plasmode_cons.R" "$1" "$2" '"$CV"' 2>&1 | grep -v "Population size" | tail -1' >> "$LOG"
echo "=== finished $(date +%H:%M:%S) ===" >> "$LOG"
