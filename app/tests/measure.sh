#!/bin/bash
# measure.sh <process name> <seconds> [state.json]: 4.0 Phase 5. Every 5 s, the memory (resident, MB) and CPU (%) of the
# app and of its YouTube pages' web-content processes (their IDs from the test hooks' state.json, refreshed by the
# caller with `vsctl state`), as CSV. Read-only: it only runs ps.
# 4.0 G2: with VSCTL=<vsctl> (and the app's VS_TEST_CHANNEL), each sample also asks the app for its state and times how
# long the answer takes (ms, the main thread's responsiveness), which also refreshes state.json. -1: no answer in 5 s.
set -euo pipefail
exe=$1 secs=$2 state=${3:-}
pid=$(pgrep -x "$exe" | head -1) || { echo "$exe isn't running" >&2; exit 1; }
echo "time,app_mb,app_cpu,web_mb,web_cpu,web_processes,response_ms"
respond() {
  [[ -n ${VSCTL:-} && -n $state ]] || { echo ""; return; }
  python3 -c '
import os, subprocess, sys, time
state, vsctl = sys.argv[1:]
if os.path.exists(state): os.remove(state)
t0 = time.monotonic(); subprocess.run([vsctl, "state"])
while time.monotonic() - t0 < 5:
    if os.path.exists(state) and os.path.getsize(state) > 0: print(int((time.monotonic() - t0) * 1000)); sys.exit()
    time.sleep(0.005)
print(-1)' "$state" "$VSCTL"
}
end=$((SECONDS + secs))
while ((SECONDS < end)); do
  r=$(respond)
  web=""
  [[ -n $state && -s $state ]] && web=$(python3 -c 'import json, sys; print(",".join(sorted({str(t["webPID"]) for t in json.load(open(sys.argv[1])).get("tabs", []) if t.get("webPID")})))' "$state")
  app=$(ps -o rss=,%cpu= -p "$pid" | awk '{printf "%d,%.1f", $1 / 1024, $2}')
  pages=$( [[ -n $web ]] && ps -o rss=,%cpu= -p "$web" | awk '{m += $1; c += $2; n++} END {printf "%d,%.1f,%d", m / 1024, c, n}' || echo "0,0.0,0")
  echo "$(date +%T),$app,$pages,$r"
  sleep 5
done
