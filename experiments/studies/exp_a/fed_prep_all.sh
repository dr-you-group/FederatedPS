#!/bin/bash
# Write the per-fold site files used by the federated runs.
set -u
. "$(dirname "$0")/../../common/env.sh"
LOG=$FP_OUT/logs/fed_prep.log; : > "$LOG"
printf '%s\n' $STUDIES | xargs -P "$JOBS" -I{} sh -c \
  '$RSCRIPT "$FP_EXP/studies/exp_a/fed_prep.R" {} 2>&1 | tail -6 | sed "s/^/[{}] /"' >> "$LOG"
echo "=== done $(date +%H:%M:%S) ===" >> "$LOG"
