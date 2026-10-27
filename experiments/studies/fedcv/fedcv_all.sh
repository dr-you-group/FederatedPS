#!/bin/bash
# Federated cross-validation of the prior variance for every study.
set -u
. "$(dirname "$0")/../../common/env.sh"
LOG=$FP_OUT/logs/fedcv.log; : > "$LOG"
printf '%s\n' $STUDIES | xargs -P "$JOBS" -I{} sh -c '[ -f "$FP_OUT/fedcv/{}_summary.csv" ] && exit 0
  $RSCRIPT "$FP_EXP/studies/fedcv/fedcv.R" {} 2>&1 | tail -1' >> "$LOG"
echo "=== finished $(date +%H:%M:%S) ===" >> "$LOG"
