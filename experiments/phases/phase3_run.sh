#!/bin/bash
# Phase 3: federated runs on the five partitions written by phase3_prep.R.
# phase3_run.sh <P> <alpha> [tag]
set -e
. "$(dirname "$0")/../common/env.sh"
P=$1; AL=$2; TAG=${3:-}
for S in A B C D E; do
  RUN="p3${S}P${P}${TAG}"
  echo "--- setting $S: P=$P alpha=$AL ---"
  "$FP_EXP/validation/run_fed.sh" "p3$S" "$RUN" "$P" "$AL" s1 s2 s3 > "$FP_OUT/logs/${RUN}_run.log" 2>&1 \
    || { echo "failed $RUN"; tail -n 3 "$FP_OUT/logs/${RUN}_run.log"; }
  tail -n 1 "$FP_OUT/fedruns/$RUN/s1.log" 2>/dev/null || true
done
echo "done P=$P"
