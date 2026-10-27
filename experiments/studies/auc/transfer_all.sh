#!/bin/bash
# Transfer matrix for every study.
set -u
. "$(dirname "$0")/../../common/env.sh"
LOG=$FP_OUT/logs/transfer.log; : > "$LOG"
printf '%s\n' $STUDIES | xargs -P "$JOBS" -I{} sh -c '[ -f "$FP_OUT/transfer/{}.csv" ] && exit 0
  $RSCRIPT "$FP_EXP/studies/auc/transfer.R" {} 2>&1 | tail -9' >> "$LOG"
echo "=== finished $(date +%H:%M:%S) ===" >> "$LOG"
