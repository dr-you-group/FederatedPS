#!/bin/bash
# Keep the most recent $KEEP round directories under $1/$2.
# Keep the window large: a lagging site may still read an old round.
d="$1/$2"; KEEP=${3:-5000}
while true; do
  if [ -d "$d" ]; then
    ls -1 "$d" 2>/dev/null | sort -n | head -n -"$KEEP" \
      | sed "s|^|$d/|" | tr '\n' '\0' | xargs -0 -r rm -rf
  fi
  sleep 5
done
