#!/bin/bash
# try-browser.sh: runs this branch's YouTube browser prototype in a throwaway environment (its own history, downloads
# folder and WebKit data store), without touching ~/Applications/Video Buddy.app or your library.
#   app/tools/try-browser.sh          build and open the prototype (queue paused)
#   app/tools/try-browser.sh --clean  remove its WebKit data store (cookies, sign-in), then the whole try-out folder
set -euo pipefail
cd "$(dirname "$0")/.."
T="$HOME/Library/Caches/video-buddy-try-browser"
app="$T/Video Buddy (browser prototype).app"
launch() {   # extra open(1) args
  open -n ${TRY_BACKGROUND:+-g} -a "$app" --env VS_DATA_DIR="$T/data" "$@" --args -downloadDir "$T/downloads" -queuePaused YES
}
if [[ ${1:-} == --clean ]]; then
  [[ -d "$app" ]] || { echo "nothing to clean"; exit 0; }
  pkill -f "VideoSummarizer -downloadDir $T/downloads" || true; sleep 2
  # a fresh launch that never opens a web view can remove the store (WebKit refuses while a session uses it)
  launch -g --env VS_TEST_HOOKS=1 --env VS_TEST_CHANNEL=try --env VS_SNAPSHOT_DIR="$T"
  sleep 5
  swiftc tests/vsctl.swift -o "$T/vsctl" 2>/dev/null
  VS_TEST_CHANNEL=try "$T/vsctl" clearBrowsingData; sleep 7
  VS_TEST_CHANNEL=try "$T/vsctl" state; sleep 1
  python3 -c "import json; print(json.load(open('$T/state.json'))['browser'].get('clearReport', 'no report'))"
  pkill -f "VideoSummarizer -downloadDir $T/downloads" || true; sleep 1
  rm -rf "$T"
  # WebKit leaves its (now empty) folders behind; rmdir only removes them if they really are empty
  rmdir "$HOME/Library/WebKit/local.video-summarizer/WebsiteDataStore" "$HOME/Library/WebKit/local.video-summarizer" 2>/dev/null || true
  echo "try-out folder removed"
  exit 0
fi
mkdir -p "$T/data" "$T/downloads" "$app/Contents/MacOS" "$app/Contents/Resources/raycast"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 $(find Sources -name '*.swift' | sort) -o "$app/Contents/MacOS/VideoSummarizer"
cp Info.plist "$app/Contents/"; cp -Rp ../scripts "$app/Contents/Resources/scripts"; cp -p ../raycast/summarize.sh "$app/Contents/Resources/raycast/"
"$app/Contents/MacOS/VideoSummarizer" --selftest
codesign --force --sign - "$app" 2>/dev/null
launch
echo "Opened the prototype (YouTube is in the sidebar). When you're done: app/tools/try-browser.sh --clean"
