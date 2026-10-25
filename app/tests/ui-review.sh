#!/bin/bash
# ui-review.sh <new folder>: 4.0 G2's UI review screenshots. The test build ("Video Buddy 4.0 Test", RC rules, the fake
# downloader) on throwaway folders, with its fixtures (Library, Playlists, Watch Later, failures, a missing file), captured
# in every section and dialog, dark and light, at the minimum window size (980×660) and a wide one (1800×1100).
# Nothing real is downloaded and no AI runs; the YouTube section loads the authorized test video's page (no download).
# System alerts and the separate Settings window draw blank in snapshots: those are listed for checking by hand.
# Writes <folder>/<size>-<appearance>-<name>.png; removes the test build, its data and settings afterwards.
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:?new folder}; [[ ! -e $out ]] || { echo "refused: $out exists"; exit 2; }
mkdir -p "$out"; out=$(cd "$out" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vb-ui.XXXXXX")
id=local.video-summarizer.preview-test app="$T/Video Buddy 4.0 Test.app"
export VS_TEST_CHANNEL=uireview
vs() { "$T/vsctl" "$@"; sleep "${PAUSE:-0.8}"; }
running() { pgrep -x VideoBuddyTest > /dev/null; }
quit_app() { pkill -x VideoBuddyTest 2> /dev/null; for _ in $(seq 40); do running || return 0; sleep 0.25; done; pkill -9 -x VideoBuddyTest; sleep 1; }
cleanup() {
  quit_app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2> /dev/null
  rm -rf "$HOME/Library/WebKit/$id" "$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id" "$HOME/Library/Saved Application State/$id.savedState"
  defaults delete "$id" 2> /dev/null; rm -rf "${T:?}"
}
trap cleanup EXIT
# shot <name>: the main window (and a sheet, as -sheet) saved under this run's size and appearance
shot() {
  rm -f "$T/shots"/window*.png; vs snapshot
  for _ in $(seq 50); do [[ -s $T/shots/window.png ]] && break; sleep 0.1; done; sleep 0.5
  [[ -s $T/shots/window.png ]] && cp "$T/shots/window.png" "$out/$size-$look-$1.png"
  [[ -s $T/shots/window-1.png ]] && cp "$T/shots/window-1.png" "$out/$size-$look-$1-sheet.png"
  return 0
}

echo "building the test build in $T"
"$repo/app/tools/preview.sh" --test "$T" --rc > "$T/build.log" 2>&1 || { tail -20 "$T/build.log"; exit 1; }
swiftc "$repo/app/tests/vsctl.swift" -o "$T/vsctl" 2> /dev/null
cp "$repo/app/tests/fake-dl.sh" "$T/"; mkdir -p "$T/samples"
ffmpeg -v error -f lavfi -i testsrc=duration=4:size=1280x720:rate=25 -f lavfi -i sine=duration=4 -c:v libx264 -c:a aac -shortest "$T/samples/sample.mp4"
ffmpeg -v error -f lavfi -i sine=duration=4 "$T/samples/sample.mp3"; : > "$T/control"

for size in 980x660 1800x1100; do
  D="$T/data-$size" dl="$T/out-$size"; mkdir -p "$D" "$dl" "$T/shots"
  printf '%s\n' "# ui review" jNQXAC9IVRw > "$D/live-test-videos.txt"
  defaults write "$id" queuePaused -bool true
  open -n -g -a "$app" --env VS_DATA_DIR="$D" --env VS_SNAPSHOT_DIR="$T/shots" --env VS_TEST_HOOKS=1 --env VS_TEST_CHANNEL=uireview \
       --env VS_WINDOW_SIZE="$size" --env VS_TEST_FAKE_DOWNLOADS="$T/fake-dl.sh" --env VS_FAKE_SAMPLES="$T/samples" --env VS_FAKE_CONTROL="$T/control" \
       --args -downloadDir "$dl"
  sleep 5; vs "mute on"; vs focusWindow
  PAUSE=3 vs "loadFixtures $T/samples|$dl"
  vs "select Me at the zoo"; vs "newPlaylist Fixture series"; vs "select Cosmos"; vs "addToPlaylist Fixture series"
  vs "wlSave jNQXAC9IVRw"; vs "wlSave aqz-KE-bpKQ"; vs "wlSave Y-rmzh0PI3c"
  for look in Dark Light; do
    vs "setDefault appearance|$look"
    vs "section Home"; shot home
    vs "layout Grouped"; vs "section Library"; shot library-grouped
    vs "layout All Videos"; shot library-all
    vs "select Cosmos"; vs "tab Summary"; shot detail-summary
    vs "tab Transcript"; shot detail-transcript
    vs "tab Downloads"; shot detail-downloads
    vs "tab Video"; vs "section Favorites"; shot favorites
    vs "section Playlists"; shot playlists
    vs "openPlaylist Fixture series"; shot playlist-page
    for s in Ready Problems Preparing All; do vs "setDefault downloadsShow|$s"; vs "section Downloads"; shot "downloads-$s"; done
    vs "section Queue"; vs showSteps; shot queue
    vs "section Watch Later"; shot watch-later
    vs "section Settings"; shot settings
    PAUSE=6 vs "browse https://www.youtube.com/watch?v=lkm-WEHQtNc"; shot youtube
    vs "section Library"
    # dialogs
    vs "link https://youtu.be/BaW_jenozKc"; vs "start video"; shot dialog-declaration; vs "nativeClick declareCancel"
    PAUSE=3 vs "prepareFor jNQXAC9IVRw,QjMwIk6Crbc,BaW_jenozKc"; shot dialog-prepare; vs "nativeClick prepareCancel"
    vs "openURL videobuddy://request?action=video&url=https%3A%2F%2Fyoutu.be%2FjNQXAC9IVRw"; shot dialog-request; vs "nativeClick externalCancel"
    vs "link https://youtu.be/jNQXAC9IVRw"; vs "start video"; shot dialog-copy-prompt; vs "copyDecision cancel"
    vs "section Downloads"; vs "setDefault downloadsShow|Problems"; vs lookForMoved; shot downloads-relink
    vs "link "
  done
  quit_app
done
ls "$out" | wc -l | tr -d ' ' | sed 's/$/ screenshots in '"${out//\//\\/}"'/'
