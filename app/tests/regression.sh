#!/bin/bash
# regression.sh: 4.0 Phase 5. Builds the test build ("Video Buddy 4.0 Test": its own bundle ID, settings and WebKit data)
# and drives it through every phase's main behaviour on throwaway folders, with the fake downloader (app/tests/fake-dl.sh):
# nothing real is downloaded and no AI runs. First with the Preview's rules, then with the RC's (locks, live-test list).
# Afterwards the test build, its data, WebKit data and settings are removed. Your apps and their data aren't touched.
#   app/tests/regression.sh        prints one line per check, then "regression: N passed, M failed" (exit 1 if any failed)
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vb-regression.XXXXXX")
id=local.video-summarizer.preview-test
app="$T/Video Buddy 4.0 Test.app"
pass=0 fail=0
export VS_TEST_CHANNEL=regression

ok() { if [[ $2 == True ]]; then pass=$((pass + 1)); echo "  ✓ $1"; else fail=$((fail + 1)); echo "  ✗ $1  (got: ${3:-$2})"; fi; }
vs() { "$T/vsctl" "$@"; sleep 0.4; }
# q <python expression on the state s>: asks the running test build for its state and evaluates the expression
q() {
  rm -f "$T/shots/state.json"; "$T/vsctl" state
  for _ in $(seq 60); do [[ -s $T/shots/state.json ]] && break; sleep 0.1; done
  python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$T/shots/state.json" "$1" 2> /dev/null || echo "?"
}
# waitfor <python condition> [seconds]: waits until it holds; prints True or False
waitfor() { local end=$((SECONDS + ${2:-20})); while ((SECONDS < end)); do [[ $(q "$1") == True ]] && { echo True; return; }; sleep 0.5; done; echo False; }
check() { ok "$1" "$(waitfor "$2" "${3:-20}")" "$(q "${4:-$2}")"; }
running() { pgrep -x VideoBuddyTest > /dev/null; }
quit_app() { pkill -x VideoBuddyTest 2> /dev/null; for _ in $(seq 40); do running || return 0; sleep 0.25; done; pkill -9 -x VideoBuddyTest; sleep 1; }
# launch <data folder> [fake]: the test build on that folder, downloads in $out (fake: with the fake downloader)
out="$T/out"
launch() {
  local data=$1 extra=()
  [[ ${2:-} == fake ]] && extra=(--env VS_TEST_FAKE_DOWNLOADS="$T/fake-dl.sh" --env VS_FAKE_SAMPLES="$T/samples"
                                 --env VS_FAKE_CONTROL="$T/control" --env VS_TEST_FREE_FINAL_FILE="$T/free-final" --env VS_TEST_FREE_TEMP_FILE="$T/free-temp"
                                 --env VS_TEST_CLAUDE="$T/claude-stub")
  mkdir -p "$data" "$out" "$T/shots"
  open -n -g -a "$app" --env VS_DATA_DIR="$data" --env VS_SNAPSHOT_DIR="$T/shots" --env VS_TEST_HOOKS=1 --env VS_TEST_CHANNEL=regression \
       --env VS_WINDOW_SIZE=1400x900 ${extra[@]+"${extra[@]}"} --args -downloadDir "$out"
  for _ in $(seq 80); do [[ $(q 'True') == True ]] && break; sleep 0.25; done
  vs "mute on"; vs "section Library"
}
# sheetclick <probe>: a button on the request sheet, once the sheet has settled (its title arrives a moment later and the
# sheet resizes, which moved the button under an early click); clicked once more if the sheet is still open
sheetclick() { sleep 2; vs "nativeClick $1"; [[ $(waitfor "s['external'] == {}" 4) == True ]] || vs "nativeClick $1"; }
request() { python3 -c 'import sys, urllib.parse; print("videobuddy://request?" + urllib.parse.urlencode({"action": sys.argv[1], "url": sys.argv[2]}))' "$1" "$2"; }
cleanup() {
  if [[ -d $app ]]; then
    quit_app
    # the test build's WebKit data goes through WebKit first (preview.sh --remove does the same), then the folders
    open -n -g -a "$app" --env VS_DATA_DIR="$T/data-clean" --env VS_SNAPSHOT_DIR="$T/shots" --env VS_TEST_HOOKS=1 --env VS_TEST_CHANNEL=regression
    sleep 4; "$T/vsctl" clearBrowsingData; sleep 6; quit_app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2> /dev/null
  fi
  rm -rf "$HOME/Library/WebKit/$id" "$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id" "$HOME/Library/Saved Application State/$id.savedState"
  defaults delete "$id" 2> /dev/null
  rm -rf "${T:?}"
}
trap cleanup EXIT

echo "Building the test builds and samples in $T"
swiftc "$repo/app/tests/vsctl.swift" -o "$T/vsctl" 2> /dev/null
mkdir -p "$T/samples"
say -o "$T/samples/speech.aiff" "This is a short test of transcription on this Mac."
ffmpeg -v error -f lavfi -i testsrc=duration=4:size=640x360:rate=25 -i "$T/samples/speech.aiff" -af apad -t 4 -c:v libx264 -c:a aac "$T/samples/sample.mp4"
ffmpeg -v error -i "$T/samples/speech.aiff" -af apad -t 4 "$T/samples/sample.mp3"
# 4.0: a stand-in Claude CLI (never the real one): records each call, answers as $T/claude-mode says
cat > "$T/claude-stub" <<EOF
#!/bin/bash
echo "\$*" >> "$T/claude-calls"; [[ \${1:-} == -p ]] && cat > /dev/null
case \$(cat "$T/claude-mode" 2> /dev/null) in
  budget) echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":1.01,"usage":{},"modelUsage":{"claude-haiku-5-5":{}}}'; exit 1 ;;
  *) echo '{"type":"result","subtype":"success","is_error":false,"result":"**TL;DR**\\nA stub summary.","total_cost_usd":0.005,"usage":{"input_tokens":9,"output_tokens":900},"modelUsage":{"claude-haiku-5-5":{}}}' ;;
esac
EOF
chmod +x "$T/claude-stub"; echo ok > "$T/claude-mode"
stubcalls() { [[ -f $T/claude-calls ]] && wc -l < "$T/claude-calls" | tr -d ' ' || echo 0; }
echo 100000000000 > "$T/free-final"; echo 100000000000 > "$T/free-temp"; : > "$T/control"
# the fake downloader runs from here: the project folder is on the Desktop, which macOS guards with a permission prompt
cp "$repo/app/tests/fake-dl.sh" "$T/fake-dl.sh"
"$repo/app/tools/preview.sh" --test "$T" > "$T/build.log" 2>&1 || { echo "test build failed:"; tail -20 "$T/build.log"; exit 1; }
grep -o 'selftest: .*' "$T/build.log"

A=jNQXAC9IVRw B=M7E_tARS0hs C=aqz-KE-bpKQ D=BaW_jenozKc E=9bZkp7q19f0
echo "== Preview rules, fake downloader"
defaults write "$id" queuePaused -bool false
launch "$T/data" fake
check "identity: the test build, Preview rules, its own data folder" "s['build']['isPreview'] and not s['build']['isRC'] and s['build']['dataDir'] == '$T/data'"
vs "link https://youtu.be/$A"; vs "start video"
check "gate (link field): no declaration opens the sheet for that video, nothing queued" "s['declarationFor'].startswith('$A queue') and s['queueKeys'] == []"
vs "nativeClick declareCancel"
vs "declareOnly $A|regression"; vs "start video"
# (the first download after a fresh build has taken up to 45 s on this Mac; later ones take about 2 s)
check "declared: queued, downloaded by the fake runner, on this Mac" "any('fake $A' in m for m in s['media'])" 90 "s['media'], s['failed'], s['notice']"
ok "the file is in the test downloads folder" "$([[ -f "$T/out/fake $A.mp4" ]] && echo True || echo False)"
waitfor "s['running'] == '' and s['queueKeys'] == []" 60 > /dev/null
vs "pauseQueue"; vs "declareOnly $B|regression"; vs "link https://youtu.be/$B"; vs "start video"; vs "start video"
check "duplicates: Download twice is one job" "len([k for k in s['queueKeys'] if '$B' in k]) == 1"
# (the test's folders are all inside the temporary folder, so both simulated volumes go low)
echo 5000000000 > "$T/free-final"; echo 5000000000 > "$T/free-temp"; vs "resumeQueue"
check "low space before a job: the queue pauses with the reason, the job stays queued" "s['pauseReason'] != '' and any('$B' in k for k in s['queueKeys'])"
echo 100000000000 > "$T/free-final"; echo 100000000000 > "$T/free-temp"; vs "resumeQueue"
check "space again: it carries on" "any('fake $B' in m for m in s['media'])" 30
echo "$C blocked" >> "$T/control"; vs "declareOnly $C|regression"; vs "link https://youtu.be/$C"; vs "start video"
check "unavailable (members-only): the reason, nothing queued" "'Members-only' in s['notice'] and not any('$C' in k for k in s['queueKeys'])"
echo "$D fail" >> "$T/control"; vs "declareOnly $D|regression"; vs "link https://youtu.be/$D"; vs "start video"
check "a failed download is listed with Retry" "any(f.startswith('video') for f in s['failed'])" 30 "s['failed']"
echo "$D ok" >> "$T/control"; vs "retryFailed"
check "Retry goes through the checks again and succeeds" "any('fake $D' in m for m in s['media'])" 30
# G1a change A: something already on this Mac is only downloaded again when you say so
vs "link https://youtu.be/$A"; vs "start video"
check "another copy (link field): asked first, nothing queued" "s['pendingCopy'].startswith('video') and s['queueKeys'] == []"
vs "copyDecision cancel"
check "…Cancel: nothing queued, nothing running" "s['pendingCopy'] == '' and s['queueKeys'] == [] and s['running'] == ''"
vs "libraryAction $A|again-video"
check "another copy (Library's Download Again): asked first too" "s['pendingCopy'].startswith('video') and s['queueKeys'] == []"
vs "copyDecision cancel"
ok "…still one file of it" "$([[ $(ls "$T/out" | grep -c "$A") == 1 ]] && echo True || echo False)"
vs "start video"
# G1b: the prompt names what's here (the fake sample is 360p) and what would come (the fake formats' 1080p)
check "the copy prompt says what's here and what would come" "'1080p copy' in s['copyPrompt'].get('title', '') and 'at 360p' in s['copyPrompt'].get('message', '')" 15 "s['copyPrompt']"
vs "copyDecision copy"
check "Download Another Copy: a second, separate file" "any('fake $A (2)' in m for m in s['media'])" 30 "s['media']"
# G1b: each copy's Play button plays exactly that file
vs "section Downloads"; sleep 1; vs "nativeClick play fake $A (2).mp4"
check "Downloads: a copy's Play opens exactly that file" "s['playback']['path'].endswith('fake $A (2).mp4')" 10 "s['playback'], s['hookResult']"
vs "nativeClick play fake $A.mp4"
check "…and the other copy's, its own" "s['playback']['path'].endswith('fake $A.mp4')" 10 "s['playback']"
vs "stopPlayer"; vs "section Library"; vs "link https://youtu.be/$A"; vs "start audio"
check "the audio of the same video downloads (no copy question: no audio yet)" "any('fake $A.mp3' in m for m in s['media'])" 30 "s['media'], s['pendingCopy']"
echo "$E slow" >> "$T/control"; vs "declareOnly $E|regression"; vs "link https://youtu.be/$E"; vs "start video"
waitfor "s['running'] == 'youtube:$E'" > /dev/null; vs "cancel"
check "cancel: stopped, no file left" "s['running'] == '' and not any('$E' in m for m in s['media'])"
ok "cancel: nothing of it in the downloads folder" "$(ls "$T/out" | grep -q "$E" && echo False || echo True)"
check "cancel pauses the queue (as in 3.1)" "s['build']['paused']"
vs "resumeQueue"
vs "prepareFor $A,$E"
check "Prepare: a video on this Mac is 'have it', another is ready" "any(r.startswith('$A') and 'haveIt' in r for r in s['prepare']) and any(r.startswith('$E') and 'ready' in r for r in s['prepare'])"
vs "nativeClick prepareCancel"
vs "wlSave $A"; vs "wlSave $A"
check "Watch Later: saved once, however often" "[w['id'] for w in s['watchLater']] == ['$A']"
check "Watch Later: its status follows the library" "any('available offline' in t.lower() for t in s['watchLater'][0]['status'])" 10 "s['watchLater'][0]['status']"
vs "tabNew https://www.youtube.com/watch?v=$A"; vs "tabNewBehind https://www.youtube.com/watch?v=$E"; vs "tabDuplicate"
check "tabs: new, background and duplicate" "len(s['tabs']) >= 3" 15 "s['tabs']"
n=$(q "len(s['tabs'])")
vs "tabClose $n"; vs "tabReopen"
check "tabs: close and reopen" "len(s['tabs']) == $n" 10
vs "tabMove 1|$n"
check "the bar follows the active tab's video" "s['bar'].get('id', '') == next((t['videoID'] for t in s['tabs'] if t['active']), 'none') or s['bar'].get('video') == 'none'" 15 "s['bar'], s['tabs']"
# G1b: with the video and its audio both here, the bar still offers Play Audio, and it plays the MP3
vs "browse https://www.youtube.com/watch?v=$A"; waitfor "s['bar'].get('id') == '$A' and s['bar'].get('audio') == 'offline'" 20 > /dev/null
vs "nativeClick playAudio"
check "the bar's Play Audio, with the video here too, plays the MP3" "s['playback']['path'].endswith('.mp3')" 10 "s['playback'], s['hookResult'], s['bar']"
vs "stopPlayer"
# external requests (videobuddy://): checked, then they only ask
vs "section Library"
open -g -a "$app" "$(request video "https://youtu.be/$E")"
check "request: shown for you to confirm, nothing queued" "s['external'].get('youtubeID') == '$E' and s['queueKeys'] == []"
open -g -a "$app" "$(request audio "https://youtu.be/$A")"
check "request: a second one while one waits is ignored" "'finish what' in s['notice'] and s['external'].get('youtubeID') == '$E'"
sheetclick externalCancel
check "request: Cancel queues nothing" "s['external'] == {} and s['queueKeys'] == [] and s['running'] == ''"
open -g -a "$app" "$(request video "https://vimeo.com/76979871")"
check "request: anything but YouTube is refused with a notice" "'Ignored a request' in s['notice'] and s['external'] == {}"
open -g -a "$app" "videobuddy://request?action=video&url=https%3A%2F%2Fyoutu.be%2F$A&queue=now"
check "request: an extra parameter is refused" "'Ignored a request' in s['notice'] and s['external'] == {}"
vs "wlRemove $A"
said=$(VB_APP=$app "$repo/raycast/download-video.sh" "https://www.youtube.com/watch?v=$E" 2>&1)
ok "Raycast: a YouTube link is handed over, not downloaded" "$([[ $said == "Sent to Video Buddy 4.0 Test"* ]] && echo True || echo False)" "$said"
check "Raycast: the app shows it for you to confirm" "s['external'].get('youtubeID') == '$E' and s['external'].get('kind') == 'video'"
sheetclick externalDownload
check "request: Download goes on, and it's downloaded once declared" "any('fake $E' in m for m in s['media'])" 30
said=$(VB_BUNDLE_ID=local.video-summarizer "$repo/raycast/download-audio.sh" "https://youtu.be/$A" 2>&1); code=$?
ok "Raycast: with 3.1 as the target (no videobuddy://) it stops and downloads nothing" "$([[ $code != 0 && $said == *"isn't installed"* ]] && echo True || echo False)" "$code $said"
said=$(VB_APP=$app "$repo/raycast/summarize.sh" "https://youtu.be/$A" 2>&1)
check "Raycast Summarize: handed over too (as a summary)" "s['external'].get('kind') == 'summary'"
sheetclick externalCancel
# 4.0: paid AI summaries, with the stand-in CLI only (off until allowed; Haiku 5.5, $1 cap, no retry)
F=YbJOTdZBX1g; vs "declareOnly $F|regression"; vs "section Library"
vs "link https://youtu.be/$F"; vs "start summary"
check "AI off by default: Summarize refused, nothing queued, the CLI never called" "'AI summaries are off' in s['notice'] and s['queueKeys'] == [] and not s['build']['aiApproved']" 10 "s['notice'], s['queueKeys']"
ok "…no call" "$([[ $(stubcalls) == 0 ]] && echo True || echo False)" "$(stubcalls)"
vs "setDefault aiSummariesApproved|1"; vs "start summary"
check "allowed: the full Summarize (fake download, on-device transcript, the stand-in) saves a summary" "any('$F' in m for m in s['media']) and s['running'] == '' and any(j['kind'] == 'summary' and j['status'] == 'succeeded' and j['summaryChars'] > 0 for j in s['selectedJobs'])" 120 "s['selectedJobs'], s['failed'], s['banner']"
check "…the job's log has the model, cost and tokens" "any('AI: claude-haiku-5-5' in l for l in s['lastOutput'])" 5 "s['lastOutput'][-5:]"
ok "…exactly one request, Haiku 5.5, \$1 cap" "$([[ $(stubcalls) == 1 && $(cat "$T/claude-calls") == "-p --model claude-haiku-5-5 --output-format json --max-turns 1 --max-budget-usd 1.00 "* ]] && echo True || echo False)" "$(cat "$T/claude-calls" 2> /dev/null)"
vs summarizeTranscript
check "Regenerate: a second summary, one more request" "sum(1 for j in s['selectedJobs'] if j['kind'] == 'summary' and j['status'] == 'succeeded') == 2 and s['running'] == ''" 60 "s['selectedJobs']"
echo budget > "$T/claude-mode"; vs summarizeTranscript
check "a failed request (over the cap): failed, the saved summaries unchanged" "s['running'] == '' and s['queueKeys'] == [] and sum(1 for j in s['selectedJobs'] if j['kind'] == 'summary' and j['status'] == 'succeeded') == 2 and any(f.startswith('resummarize') for f in s['failed'])" 60 "s['selectedJobs'], s['failed']"
sleep 5
ok "…never retried by itself: still 3 requests, nothing queued" "$([[ $(stubcalls) == 3 && $(q "s['queueKeys'] == [] and s['running'] == ''") == True ]] && echo True || echo False)" "$(stubcalls)"
echo ok > "$T/claude-mode"; vs "setDefault aiSummariesApproved|0"
vs summarizeTranscript
check "AI turned off again: Regenerate refused, no request" "'AI summaries are off' in s['notice'] and s['queueKeys'] == []" 10 "s['notice']"
ok "…no call" "$([[ $(stubcalls) == 3 ]] && echo True || echo False)" "$(stubcalls)"
# 3.1 features
vs "select fake $A"; vs "play"
check "player: a downloaded video plays" "s['playback']['playing'] and '$A' in s['playback']['path']" 10 "s['playback']"
vs "stopPlayer"; vs "newPlaylist Regression"
check "playlists: a new one with the selected video" "'Regression (1)' in s['playlists']" 10 "s['playlists']"
vs "wlSave $B"; vs "clearAll"
check "Clear All History empties the library but keeps Watch Later" "s['visible'] == [] and [w['id'] for w in s['watchLater']] == ['$B']" 10
vs "tabNew https://www.youtube.com/watch?v=$B"; sleep 2
tabs=$(q "len(s['tabs'])"); quit_app; launch "$T/data" fake
check "tabs come back after a restart" "len(s['tabs']) == $tabs" 15
quit_app

echo "== RC rules (the test build with VBReleaseCandidate)"
"$repo/app/tools/preview.sh" --test "$T" --rc > "$T/build-rc.log" 2>&1 || { echo "RC test build failed:"; tail -20 "$T/build-rc.log"; exit 1; }
grep -o 'selftest: .*' "$T/build-rc.log"
R="$T/data-rc"; out="$T/out-rc"; mkdir -p "$R"; printf '%s\n' "# regression" "$A" > "$R/live-test-videos.txt"
defaults write "$id" queuePaused -bool false; defaults write "$id" rcLiveDownloads -bool false; defaults write "$id" rcAISummaries -bool false
launch "$R"
check "identity: RC rules, both locks off (per job: downloads and AI, not the queue)" "s['build']['isRC'] and s['build']['canRun'] and s['build']['jobsLock'] == '' and 'live downloads' in s['build']['downloadsLock'] and s['build']['liveTestList'] == ['youtube:$A']" 10 "s['build']"
check "the sidebar says what's locked" "s['build']['badge'] == '4.0 RC · downloads locked · AI locked'"
vs "declareOnly $A|regression"; vs "link https://youtu.be/$A"; vs "start video"
check "live downloads not approved: queued, and it waits" "any('$A' in k for k in s['queueKeys']) and 'approved' in s['notice']"
sleep 3
check "…nothing runs" "s['running'] == '' and any('$A' in k for k in s['queueKeys'])"
ok "…and nothing is in its downloads folder" "$([[ -z $(ls "$out") ]] && echo True || echo False)"
vs "clearQueue"; quit_app
launch "$R" fake
vs "declareOnly $A|regression"; vs "declareOnly $C|regression"
vs "link https://youtu.be/$C"; vs "start video"
check "a declared video that isn't on the live-test list: refused, nothing queued" "\"isn't on\" in s['notice'] and s['queueKeys'] == []"
vs "link https://youtu.be/$A"; vs "start summary"
check "an AI summary before it's approved: refused" "'AI summaries' in s['notice'] and s['queueKeys'] == []"
vs "enqueueOptions $C|video|720|-|unknown"
check "the database refuses it too, whoever asks" "s['hookResult'].startswith('refused $C') and 'live-test list' in s['hookResult']" 10 "s['hookResult']"
vs "start video"
check "a listed, declared video downloads (fake)" "any('fake $A' in m for m in s['media'])" 30 "s['media'], s['notice']"
printf '%s\n' "$A" "$B" > "$R/live-test-videos.txt"; vs "declareOnly $B|regression"
vs "pauseQueue"; vs "link https://youtu.be/$B"; vs "start video"
printf '%s\n' "$A" > "$R/live-test-videos.txt"; vs "resumeQueue"
check "taken off the list after queueing: the runner's last check refuses it" "any(f.startswith('video') for f in s['failed']) and not any('fake $B' in m for m in s['media'])" 30 "s['failed'], s['banner']"
vs "prepareFor $C"
check "Prepare shows an unlisted video as not allowed" "any(r.startswith('$C') and 'live-test' in r for r in s['prepare'])" 15 "s['prepare']"
vs "nativeClick prepareCancel"; waitfor "s['prepare'] == []" 10 > /dev/null
open -g -a "$app" "$(request video "https://youtu.be/$C")"; waitfor "s['external'] != {}" > /dev/null; sheetclick externalDownload
check "a request for an unlisted video: refused after Download" "\"isn't on\" in s['notice'] and s['queueKeys'] == []" 20 "s['notice'], s['external'], s['queueKeys']"
quit_app

echo "== RC rules: the locks are separate (no fake downloader, no window, AI locked)"
defaults write "$id" queuePaused -bool false; launch "$R"
vs "enqueueOptions $A|video|720|-|unknown"
check "a listed, declared download outside a window: queued, and it waits" "s['hookResult'].startswith('queued $A') and any(k.startswith('video') for k in s['queueKeys']) and s['running'] == ''" 10 "s['hookResult'], s['queueKeys']"
vs "selectKey youtube:$A"; vs "transcribe"
check "…while an on-device transcript of a file already here runs and is saved (real Whisper)" "any(j['kind'] == 'transcript' and j['status'] == 'succeeded' and j['segments'] > 0 for j in s['selectedJobs'])" 120 "s['selectedJobs'], s['failed'], s['banner']"
check "…and the download still waits" "any(k.startswith('video') for k in s['queueKeys']) and s['running'] == ''" 5 "s['queueKeys'], s['running']"
vs "clearQueue"; quit_app

echo "== RC rules: the live-download window (no fake downloader; an empty, paused queue, so nothing can run)"
G="$T/data-window"; out="$T/out-window"
grant() { defaults write "$id" rcLiveDownloads -bool true; defaults write "$id" rcLiveGrantUntil -int $(($(date +%s) + $1))
          defaults write "$id" rcLiveGrantClaimed -bool false; defaults write "$id" queuePaused -bool true; }
setting() { defaults read "$id" "$1" 2> /dev/null || echo none; }
grant 25; launch "$G"
check "a window: this launch claims it and may download" "s['build']['downloadsLock'] == '' and s['queueKeys'] == [] and s['running'] == ''" 10 "s['build']"
ok "…claimed, so no other launch can use it" "$([[ $(setting rcLiveGrantClaimed) == 1 ]] && echo True || echo False)"
check "when it ends: locked again, the queue paused" "s['build']['downloadsLock'] != '' and s['build']['paused']" 40 "s['build']"
written_back() { local end=$((SECONDS + 10)); while ((SECONDS < end)); do
  [[ $(setting rcLiveDownloads) == 0 && $(setting queuePaused) == 1 && $(setting rcLiveGrantUntil) == none ]] && { echo True; return; }; sleep 0.5; done; echo False; }
ok "…and written back: rcLiveDownloads 0, queuePaused 1, no window" "$(written_back)" "rcLiveDownloads $(setting rcLiveDownloads), queuePaused $(setting queuePaused), until $(setting rcLiveGrantUntil)"
quit_app
grant 600; launch "$G"
check "a new window: allowed in this launch" "s['build']['downloadsLock'] == ''" 10 "s['build']"
quit_app; launch "$G"
check "after a restart: locked again" "s['build']['downloadsLock'] != '' and s['build']['paused']" 10 "s['build']"
ok "…and written back" "$([[ $(setting rcLiveDownloads) == 0 && $(setting rcLiveGrantUntil) == none ]] && echo True || echo False)"
quit_app
defaults write "$id" rcLiveDownloads -bool true; defaults write "$id" rcLiveGrantUntil -int $(($(date +%s) + 7200)); defaults write "$id" rcLiveGrantClaimed -bool false
launch "$G"
check "a window longer than 90 minutes isn't accepted" "s['build']['downloadsLock'] != ''" 10 "s['build']"
quit_app

echo "regression: $pass passed, $fail failed"
((fail == 0))
