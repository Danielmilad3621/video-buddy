#!/bin/bash
# measure.sh <process name> <seconds> [state.json]: 4.0 Phase 5. Every 5 s, the memory (resident, MB) and CPU (%) of the
# app and of its YouTube pages' web-content processes (their IDs from the test hooks' state.json, refreshed by the
# caller with `vsctl state`), as CSV. Read-only: it only runs ps.
set -euo pipefail
exe=$1 secs=$2 state=${3:-}
pid=$(pgrep -x "$exe" | head -1) || { echo "$exe isn't running" >&2; exit 1; }
echo "time,app_mb,app_cpu,web_mb,web_cpu,web_processes"
end=$((SECONDS + secs))
while ((SECONDS < end)); do
  web=""
  [[ -n $state && -s $state ]] && web=$(python3 -c 'import json, sys; print(",".join(sorted({str(t["webPID"]) for t in json.load(open(sys.argv[1])).get("tabs", []) if t.get("webPID")})))' "$state")
  app=$(ps -o rss=,%cpu= -p "$pid" | awk '{printf "%d,%.1f", $1 / 1024, $2}')
  pages=$( [[ -n $web ]] && ps -o rss=,%cpu= -p "$web" | awk '{m += $1; c += $2; n++} END {printf "%d,%.1f,%d", m / 1024, c, n}' || echo "0,0.0,0")
  echo "$(date +%T),$app,$pages"
  sleep 5
done
