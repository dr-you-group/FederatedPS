#!/bin/bash
# Balance with the randomisation reference: the three large sites (needs exp_a results)
# and the small-site settings.
set -u
. "$(dirname "$0")/../../common/env.sh"
LOG=$FP_OUT/logs/smd_rct.log; : > "$LOG"
{ for s in $STUDIES; do echo "A $s x x"; done
  for s in $STUDIES; do for n in 5000 2000 1000 500; do echo "B $s sweep $n"; done; done
  for s in $STUDIES; do for st in synpuf cluster homo; do echo "B $s $st 1000"; done; done; } |
xargs -P "$JOBS" -L 1 sh -c 'if [ "$0" = A ]; then $RSCRIPT "$FP_EXP/studies/balance/expA_rct.R" "$1" > /dev/null 2>&1
  else [ -f "$FP_OUT/smd_rct/$1__$2_$3.csv" ] || $RSCRIPT "$FP_EXP/studies/balance/smd_rct.R" "$1" "$2" "$3" 2>&1 | grep -v "Population size" | tail -1; fi' >> "$LOG"
echo "=== finished $(date +%H:%M:%S) ===" >> "$LOG"
