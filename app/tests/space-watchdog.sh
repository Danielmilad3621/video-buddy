#!/bin/bash
# space-watchdog.sh <filler pid> <test volume> [min free GB, 100] [max drop GB, 10]: 4.0 G1b-2's guard for the bounded
# low-storage test (prepared; it runs only with your approval). Every second it reads your disk's real free space (df on
# /System/Volumes/Data, which leaves out purgeable space, so it errs low). If free space falls below the minimum, or by more
# than the allowed drop below where it started, it stops the filler, cancels the RC's current job (vsctl cancel on
# VS_TEST_CHANNEL), detaches the test volume and exits 1. It ends with 0 when the filler has finished without that.
#   VS_WATCHDOG_FREE_CMD   a command printing free bytes instead of df (to check the watchdog itself)
set -uo pipefail
filler=$1 volume=$2 min=$((${3:-100} * 1000000000)) drop=$((${4:-10} * 1000000000))
vsctl=${VSCTL:-$(dirname "$0")/vsctl}
free_bytes() {
  if [[ -n ${VS_WATCHDOG_FREE_CMD:-} ]]; then eval "$VS_WATCHDOG_FREE_CMD"; else df -k /System/Volumes/Data | awk 'NR == 2 {print $4 * 1024}'; fi
}
start=$(free_bytes)
echo "watchdog: start $((start / 1000000000)) GB free; abort below $((min / 1000000000)) GB or $((drop / 1000000000)) GB under the start"
while kill -0 "$filler" 2> /dev/null; do
  now=$(free_bytes)
  if ((now < min || start - now > drop)); then
    echo "watchdog: ABORT at $((now / 1000000000)) GB free ($(((start - now) / 1000000000)) GB under the start)"
    kill "$filler" 2> /dev/null; sleep 1; kill -9 "$filler" 2> /dev/null
    [[ -x $vsctl ]] && "$vsctl" cancel 2> /dev/null
    if [[ -d $volume ]]; then hdiutil detach "$volume" -force > /dev/null 2>&1 && echo "watchdog: $volume detached"; fi
    echo "watchdog: filler stopped, the RC's job cancelled"
    exit 1
  fi
  sleep 1
done
echo "watchdog: filler finished; lowest reading kept within the limits"
exit 0
