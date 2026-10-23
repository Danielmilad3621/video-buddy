#!/bin/bash
# rc-live-window.sh grant <minutes> | lock | status: 4.0 G1a. Opens or closes Video Buddy 4.0 RC's live-download window.
#   grant N   (1–90, only while the RC is quit) rcLiveDownloads on until now + N minutes, for the RC's next launch only;
#             also starts a safety timer that locks everything again when the window ends, whatever else happens
#   lock      rcLiveDownloads off, the queue paused, the window removed, the safety timer stopped
#   status    the RC's lock settings
# The RC enforces the window itself as well (LiveGrant in app/Sources/Prompts.swift): a second launch, or the end of the
# window, locks it again. AI summaries (rcAISummaries) are never touched here.
set -euo pipefail
id=local.video-summarizer.rc
timer="$HOME/Library/Application Support/Video Buddy 4.0 RC/.live-window-timer.pid"
lock_all() {
  defaults write "$id" rcLiveDownloads -bool false
  defaults write "$id" queuePaused -bool true
  defaults delete "$id" rcLiveGrantUntil 2> /dev/null || true
  defaults delete "$id" rcLiveGrantClaimed 2> /dev/null || true
}
case ${1:-status} in
  grant)
    m=${2:-}
    [[ $m =~ ^[0-9]+$ ]] && ((m >= 1 && m <= 90)) || { echo "usage: rc-live-window.sh grant <1–90 minutes>"; exit 2; }
    if pgrep -x VideoBuddyRC > /dev/null; then echo "Quit Video Buddy 4.0 RC first: its next launch claims the window."; exit 3; fi
    until=$(($(date +%s) + m * 60))
    defaults write "$id" rcLiveDownloads -bool true
    defaults write "$id" rcLiveGrantUntil -int "$until"   # whole seconds: -float rounds by up to a minute
    defaults write "$id" rcLiveGrantClaimed -bool false
    mkdir -p "$(dirname "$timer")"
    nohup "$0" _timer "$until" > /dev/null 2>&1 &
    echo $! > "$timer"
    echo "Live downloads allowed for the RC's next launch, until $(date -r "$until" +%H:%M); safety timer $(cat "$timer")."
    ;;
  _timer)
    while (($(date +%s) < $2)); do sleep 10; done
    lock_all
    rm -f "$timer"
    exit 0
    ;;
  lock)
    if [[ -f $timer ]]; then kill "$(cat "$timer")" 2> /dev/null || true; rm -f "$timer"; fi
    lock_all
    ;;
  status) ;;
  *) echo "usage: rc-live-window.sh grant <minutes> | lock | status"; exit 2 ;;
esac
defaults read "$id" 2> /dev/null | grep -E 'rcLive|rcAI|queuePaused' || echo "(no RC settings yet)"
