#!/bin/bash
# Small-site consortia: every study x K in {3, 5, 10} x partner source {mimic, mixed}, n = 1000.
# Pass "cv" to choose the prior variance by CV.
set -u
. "$(dirname "$0")/../../common/env.sh"
CV=${1:-}; SUF=${CV:+_cv}
LOG=$FP_OUT/logs/consortium$SUF.log; : > "$LOG"
for s in $STUDIES; do for K in 3 5 10; do for src in mimic mixed; do echo "$s $K 1000 $src"; done; done; done |
xargs -P "$JOBS" -I{} sh -c 'set -- {}; [ -f "$FP_OUT/consortium'"$SUF"'/$1_K$2_n$3_$4.csv" ] && exit 0
  $RSCRIPT "$FP_EXP/studies/auc/consortium.R" "$1" "$2" "$3" "$4" '"$CV"' 2>&1 | tail -1' >> "$LOG"
echo "=== finished $(date +%H:%M:%S) ===" >> "$LOG"
