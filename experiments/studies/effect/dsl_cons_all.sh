#!/bin/bash
# Data-shared lasso runs for every study x partner setting.
set -u
. "$(dirname "$0")/../../common/env.sh"
LOG=$FP_OUT/logs/dsl_cons.log; : > "$LOG"
for s in $STUDIES; do for st in synpuf cluster homo; do echo "$s $st"; done; done |
xargs -P "$JOBS" -I{} sh -c 'set -- {}; [ -f "$FP_OUT/dsl_cons/$1__$2.csv" ] && exit 0
  $RSCRIPT "$FP_EXP/studies/effect/dsl_cons.R" "$1" "$2" 2>&1 | grep -v "Population size" | tail -1' >> "$LOG"
echo "=== finished $(date +%H:%M:%S) ===" >> "$LOG"
