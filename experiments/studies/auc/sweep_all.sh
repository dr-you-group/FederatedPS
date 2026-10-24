#!/bin/bash
# Site-size sweep for every study x six sizes. Pass "cv" to choose the prior variance by CV.
set -u
. "$(dirname "$0")/../../common/env.sh"
CV=${1:-}; SUF=${CV:+_cv}
LOG=$FP_OUT/logs/sweep$SUF.log; : > "$LOG"
for s in $STUDIES; do for n in 500 1000 2000 5000 10000 20000; do echo "$s $n"; done; done |
xargs -P "$JOBS" -I{} sh -c 'set -- {}; [ -f "$FP_OUT/sweep'"$SUF"'/$1_$2.csv" ] && exit 0
  $RSCRIPT "$FP_EXP/studies/auc/sweep_size.R" "$1" "$2" '"$CV"' 2>&1 | tail -1' >> "$LOG"
echo "=== finished $(date +%H:%M:%S) ===" >> "$LOG"
