#!/bin/bash
# space-watchdog.sh <sentinel pid> <test volume> [min free GB, 100] [max drop GB, 10]: 4.0 G1b-2's guard for the bounded
# low-storage test. While the sentinel process lives, it reads your disk's real free space every second (df on
# /System/Volumes/Data, which leaves out purgeable space, so it errs low). If free space falls below the minimum, or by
# more than the allowed drop below where it started, it aborts, in this order: stops anything writing into the test
# volume (dd), cancels the RC's current job (vsctl cancel), waits until nothing has files open on the volume, then
# detaches it (never -force). It never deletes the image: lowstorage-run.sh does, once it's detached. Exit 1 on abort.
#   VS_WATCHDOG_FREE_CMD   a command printing free bytes instead of df (to check the watchdog itself)
#   VS_WATCHDOG_MARK       a file written on abort (lowstorage-run.sh reads it)
set -uo pipefail
sentinel=$1 volume=$2 min=$((${3:-100} * 1000000000)) drop=$((${4:-10} * 1000000000))
vsctl=${VSCTL:-$(dirname "$0")/vsctl}
free_bytes() {
  if [[ -n ${VS_WATCHDOG_FREE_CMD:-} ]]; then eval "$VS_WATCHDOG_FREE_CMD"; else df -k /System/Volumes/Data | awk 'NR == 2 {print $4 * 1024}'; fi
}
start=$(free_bytes)
echo "watchdog: start $((start / 1000000000)) GB free; abort below $((min / 1000000000)) GB or $((drop / 1000000000)) GB under the start"
while kill -0 "$sentinel" 2> /dev/null; do
  now=$(free_bytes)
  if ((now < min || start - now > drop)); then
    echo "watchdog: ABORT at $((now / 1000000000)) GB free ($(((start - now) / 1000000000)) GB under the start)"
    [[ -n ${VS_WATCHDOG_MARK:-} ]] && echo "abort $(date +%T) free=$now start=$start" > "$VS_WATCHDOG_MARK"
    pkill -f "of=$volume/" 2> /dev/null                  # writers into the test volume only
    [[ -x $vsctl ]] && "$vsctl" cancel 2> /dev/null
    if [[ -d $volume ]]; then
      for _ in $(seq 30); do [[ -z $(lsof +D "$volume" 2> /dev/null | tail -n +2) ]] && break; sleep 1; done
      if [[ -n $(lsof +D "$volume" 2> /dev/null | tail -n +2) ]]; then
        echo "watchdog: something still has files open on $volume; left attached (not forced): $(lsof +D "$volume" 2> /dev/null | awk 'NR > 1 {print $1"("$2")"}' | sort -u | tr '\n' ' ')"
      else
        hdiutil detach "$volume" > /dev/null 2>&1 && echo "watchdog: $volume detached" || echo "watchdog: $volume could not be detached; left as it is"
      fi
    fi
    exit 1
  fi
  sleep 1
done
echo "watchdog: done (the test ended); free space stayed within the limits"
exit 0
