#!/bin/bash
# Partners from the other (hetero) or the same (homo) covariate cluster, every study.
# Pass "cv" to choose the prior variance by CV.
set -u
. "$(dirname "$0")/../../common/env.sh"
CV=${1:-}; SUF=${CV:+_cv}
LOG=$FP_OUT/logs/hetero$SUF.log; : > "$LOG"
for s in $STUDIES; do for m in hetero homo; do echo "$s $m"; done; done |
xargs -P "$JOBS" -I{} sh -c 'set -- {}; [ -f "$FP_OUT/hetero'"$SUF"'/$1__$2.csv" ] && exit 0
  $RSCRIPT "$FP_EXP/studies/auc/hetero.R" "$1" "$2" '"$CV"' 2>&1 | tail -3' >> "$LOG"
echo "=== finished $(date +%H:%M:%S) ===" >> "$LOG"
