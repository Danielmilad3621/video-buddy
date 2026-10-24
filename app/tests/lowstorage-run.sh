#!/bin/bash
# lowstorage-run.sh <command>: 4.0 G1b-2's bounded low-storage test harness for Video Buddy 4.0 RC (only with your approval).
# It never fills your Mac's disk: everything goes into a fixed-size 8 GB disk image, created only with ≥ 108 GB free, and
# space-watchdog.sh aborts if your real free space drops below 100 GB or 10 GB under the start.
#   setup              (RC quit) records the state first, then creates and attaches the image, reserve 5 GB, starts the watchdog
#   point downloads    (RC quit) the RC's downloads folder on the image; `point default` puts it back to what it was
#   fill <GB>          writes into the image (capped) until its free space is about <GB>
#   unfill <GB>        removes filler until the image has at least <GB> free
#   status             the image's and your disk's free space, the watchdog, the RC's settings
#   cleanup | --recover   the full, ordered cleanup from the state file; safe to run again after an interruption:
#       1 filler and watchdog stopped  2 RC locked, its job cancelled, nothing left with files on the image, RC quit
#       3 image detached (never forced)  4 image deleted only once it's no longer attached  5 RC settings restored
#       6 your existing RC media checked byte for byte. Any step that can't finish safely stops it, with what's left.
# VS_LOWSTORAGE_DIR holds the state (default: a folder in $TMPDIR). VS_TEST_CHANNEL is the RC's test-hook channel.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dir=${VS_LOWSTORAGE_DIR:-${TMPDIR:-/tmp}/vb-lowstorage}
state="$dir/lowstorage-state.json"
img="$dir/vbtest.dmg" mnt=/Volumes/VBTest
id=local.video-summarizer.rc
rcdata="$HOME/Library/Application Support/Video Buddy 4.0 RC"
vsctl="$dir/vsctl"
window="$here/../tools/rc-live-window.sh"

host_free() { df -k /System/Volumes/Data | awk 'NR == 2 {print $4 * 1024}'; }
img_free() { df -k "$mnt" 2> /dev/null | awk 'NR == 2 {print $4 * 1024}'; }
gb() { awk -v b="$1" 'BEGIN {printf "%.2f GB", b / 1e9}'; }
get() { python3 -c 'import json, sys; v = json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$state" "$1"; }
attached() { hdiutil info | grep -qF "$img"; }
rc_running() { pgrep -x VideoBuddyRC > /dev/null; }
fail() { echo "lowstorage: STOPPED: $*"; echo "lowstorage: left as it is; finish later with: $0 --recover"; exit 2; }

setup() {
  [[ -e $state ]] && { echo "lowstorage: a previous run's state exists ($state): run $0 --recover first"; exit 2; }
  rc_running && { echo "lowstorage: quit Video Buddy 4.0 RC first"; exit 2; }
  local free; free=$(host_free)
  ((free >= 108000000000)) || { echo "lowstorage: only $(gb "$free") free on your disk; needs at least 108 GB. Nothing done."; exit 2; }
  mkdir -p "$dir"
  swiftc "$here/vsctl.swift" -o "$vsctl" 2> /dev/null
  # the state first, so any later step can be undone
  python3 - "$state" "$img" "$mnt" "$free" \
    "$(defaults read "$id" downloadDir 2> /dev/null)" "$(defaults read "$id" offlineReserveGB 2> /dev/null)" <<'PY'
import json, sys
s, img, mnt, free, dl, reserve = sys.argv[1:]
json.dump({"image": img, "mount": mnt, "hostFreeAtStart": int(free), "downloadDir": dl or None,
           "offlineReserveGB": int(reserve) if reserve else None, "sentinel": None, "watchdog": None}, open(s, "w"), indent=1)
PY
  (cd "$rcdata/Downloads" && shasum -a 256 -- *) > "$dir/files.sha"
  echo "lowstorage: state saved; $(wc -l < "$dir/files.sha" | tr -d ' ') RC media files checksummed"
  trap 'echo "lowstorage: setup interrupted"; cleanup; exit 2' INT TERM
  hdiutil create -size 8g -type UDIF -fs APFS -volname VBTest "$img" > /dev/null || { echo "lowstorage: couldn't create the image"; cleanup; exit 2; }
  hdiutil attach -nobrowse -mountpoint "$mnt" "$img" > /dev/null || { echo "lowstorage: couldn't attach the image"; cleanup; exit 2; }
  mkdir -p "$mnt/Downloads" "$mnt/tmp"
  defaults write "$id" offlineReserveGB -int 5
  perl -e 'sleep 7200' & local sentinel=$!
  VSCTL=$vsctl VS_WATCHDOG_MARK="$dir/watchdog-abort" "$here/space-watchdog.sh" "$sentinel" "$mnt" 100 10 > "$dir/watchdog.log" 2>&1 &
  local watchdog=$!
  python3 -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p)); s["sentinel"] = int(sys.argv[2]); s["watchdog"] = int(sys.argv[3]); json.dump(s, open(p, "w"), indent=1)' \
    "$state" "$sentinel" "$watchdog"
  trap - INT TERM
  echo "lowstorage: image attached at $mnt ($(gb "$(img_free)") free); your disk $(gb "$free") free; reserve 5 GB; watchdog $watchdog"
}

point() {
  rc_running && { echo "lowstorage: quit Video Buddy 4.0 RC first"; exit 2; }
  if [[ $1 == downloads ]]; then defaults write "$id" downloadDir -string "$mnt/Downloads"
  else local d; d=$(get downloadDir); if [[ -n $d ]]; then defaults write "$id" downloadDir -string "$d"; else defaults delete "$id" downloadDir 2> /dev/null; fi
  fi
  echo "lowstorage: RC downloadDir = $(defaults read "$id" downloadDir 2> /dev/null || echo "(default)")"
}

guard() {
  [[ -e $dir/watchdog-abort ]] && fail "the watchdog aborted: $(cat "$dir/watchdog-abort")"
  kill -0 "$(get watchdog)" 2> /dev/null || fail "the watchdog isn't running"
  attached || fail "the image isn't attached"
}

fill() {
  guard
  local target=$(($(awk -v g="$1" 'BEGIN {printf "%d", g * 1000}') * 1000000)) free mb n
  free=$(img_free); ((target >= 200000000)) || fail "won't fill the image below 0.2 GB free"
  mb=$(((free - target) / 1000000)); ((mb > 0)) || { echo "lowstorage: already at $(gb "$free") free"; return; }
  ((mb <= 8000)) || mb=8000
  n=$(ls "$mnt"/fill.* 2> /dev/null | wc -l | tr -d ' ')
  dd if=/dev/zero of="$mnt/fill.$((n + 1))" bs=1m count="$mb" 2> /dev/null
  echo "lowstorage: image $(gb "$(img_free)") free; your disk $(gb "$(host_free)") free"
}

unfill() {
  guard
  local target=$(($(awk -v g="$1" 'BEGIN {printf "%d", g * 1000}') * 1000000))
  for f in $(ls -t "$mnt"/fill.* 2> /dev/null); do (($(img_free) >= target)) && break; rm -f "$f"; done
  (($(img_free) >= target)) || fill "$1"
  echo "lowstorage: image $(gb "$(img_free)") free"
}

status() {
  echo "image: $(attached && echo "attached, $(gb "$(img_free)") free" || echo "not attached")"
  echo "your disk: $(gb "$(host_free)") free (start $(gb "$(get hostFreeAtStart)"))"
  echo "watchdog: $(kill -0 "$(get watchdog)" 2> /dev/null && echo running || echo stopped) $( [[ -e $dir/watchdog-abort ]] && cat "$dir/watchdog-abort")"
  defaults read "$id" 2> /dev/null | grep -E 'downloadDir|offlineReserveGB|rcLive|queuePaused'
}

cleanup() {
  trap - INT TERM
  [[ -e $state ]] || { echo "lowstorage: nothing to clean up (no state file)"; exit 0; }
  echo "lowstorage: cleanup"
  # 1 the filler and the watchdog
  pkill -f "of=$mnt/" 2> /dev/null
  local s w; s=$(get sentinel); w=$(get watchdog)
  [[ -n $s ]] && kill "$s" 2> /dev/null; [[ -n $w ]] && kill "$w" 2> /dev/null
  # 2 downloads stopped: the RC locked, its job cancelled, nothing with files on the image, the RC quit
  "$window" lock > /dev/null
  if rc_running; then
    VS_TEST_CHANNEL=${VS_TEST_CHANNEL:-rccheck} "$vsctl" cancel 2> /dev/null
    osascript -e "tell application id \"$id\" to quit" > /dev/null 2>&1
    for _ in $(seq 40); do rc_running || break; sleep 0.25; done
    rc_running && fail "Video Buddy 4.0 RC didn't quit (it may be asking about a running job)"
  fi
  if [[ -d $mnt ]]; then
    for _ in $(seq 30); do [[ -z $(lsof +D "$mnt" 2> /dev/null | tail -n +2) ]] && break; sleep 1; done
    [[ -z $(lsof +D "$mnt" 2> /dev/null | tail -n +2) ]] || fail "still open on $mnt: $(lsof +D "$mnt" 2> /dev/null | awk 'NR > 1 {print $1"("$2")"}' | sort -u | tr '\n' ' ')"
  fi
  # 3 detached, never forced
  if attached; then
    for _ in 1 2 3 4 5; do hdiutil detach "$mnt" > /dev/null 2>&1 && break; sleep 2; done
    attached && fail "the image couldn't be detached without forcing it"
  fi
  # 4 deleted only once it's no longer attached
  attached && fail "the image is still attached"
  rm -f "$img"
  # 5 the RC's settings as they were
  local d r; d=$(get downloadDir); r=$(get offlineReserveGB)
  if [[ -n $d ]]; then defaults write "$id" downloadDir -string "$d"; else defaults delete "$id" downloadDir 2> /dev/null; fi
  if [[ -n $r ]]; then defaults write "$id" offlineReserveGB -int "$r"; else defaults delete "$id" offlineReserveGB 2> /dev/null; fi
  # 6 your existing RC media byte for byte
  (cd "$rcdata/Downloads" && shasum -a 256 -c "$dir/files.sha" > "$dir/files.check" 2>&1) || fail "an existing RC media file changed: $(grep -v ': OK' "$dir/files.check")"
  local free start; free=$(host_free); start=$(get hostFreeAtStart)
  echo "lowstorage: done. image detached and deleted; RC downloadDir $(defaults read "$id" downloadDir 2> /dev/null || echo "(default)"), reserve $(defaults read "$id" offlineReserveGB 2> /dev/null || echo "(default, 10 GB)"); $(grep -c ': OK' "$dir/files.check") media files unchanged; your disk $(gb "$free") free (start $(gb "$start"))"
  rm -f "$state" "$dir/watchdog-abort"
}

case ${1:-status} in
  setup) setup ;;
  point) point "${2:-default}" ;;
  fill) fill "${2:?GB}" ;;
  unfill) unfill "${2:?GB}" ;;
  status) status ;;
  cleanup | --recover) cleanup ;;
  *) sed -n 2,15p "$0"; exit 2 ;;
esac
