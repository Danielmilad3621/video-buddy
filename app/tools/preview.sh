#!/bin/bash
# preview.sh: builds this branch as ~/Applications/Video Buddy 4.0 Preview.app, a separate app (its own bundle ID, library,
# downloads folder, settings and YouTube data) whose queue is locked: it never downloads or runs AI jobs.
# ~/Applications/Video Buddy.app (3.1) and its data are never touched.
#   app/tools/preview.sh           build, self-test and install (quits a running preview first); then open it from Finder
#   app/tools/preview.sh --remove  delete the preview: its YouTube data (cookies, sign-in), its library and the app
#   app/tools/preview.sh --test DIR  a test build in DIR: the same app as "Video Buddy 4.0 Test", its own identity
#                                    (settings, WebKit data, process name), so tests never touch the installed preview
set -euo pipefail
cd "$(dirname "$0")/.."
id=local.video-summarizer.preview
exe=VideoBuddyPreview
name="Video Buddy 4.0 Preview"
app="$HOME/Applications/$name.app"
data="$HOME/Library/Application Support/$name"
test=""
if [[ ${1:-} == --test ]]; then
  [[ -d ${2:-} ]] || { echo "usage: preview.sh --test <existing folder>"; exit 1; }
  id=local.video-summarizer.preview-test
  exe=VideoBuddyTest
  name="Video Buddy 4.0 Test"
  app="$(cd "$2" && pwd)/$name.app"
  data=""     # test runs always set VS_DATA_DIR (and without it the data folder is "Video Buddy 4.0 Test", not the preview's)
  test=1
fi

quit() {
  pgrep -x "$exe" > /dev/null || return 0
  echo "import AppKit; NSRunningApplication.runningApplications(withBundleIdentifier: \"$id\").forEach { _ = \$0.terminate() }" | swift - 2> /dev/null || true
  for _ in {1..20}; do pgrep -x "$exe" > /dev/null || return 0; sleep 0.5; done
  pkill -x "$exe" || true; sleep 1
}

if [[ ${1:-} == --remove ]]; then
  quit
  if [[ -d "$app" ]]; then
    # a launch with test hooks never opens a web view, so WebKit lets it remove the store (it refuses while a session uses it)
    t=$(mktemp -d)
    open -g -a "$app" --env VS_TEST_HOOKS=1 --env VS_TEST_CHANNEL=preview-remove --env VS_SNAPSHOT_DIR="$t"
    sleep 5
    swiftc tests/vsctl.swift -o "$t/vsctl" 2> /dev/null
    VS_TEST_CHANNEL=preview-remove "$t/vsctl" clearBrowsingData; sleep 7
    VS_TEST_CHANNEL=preview-remove "$t/vsctl" state; sleep 1
    python3 -c "import json, sys; print('WebKit store:', json.load(open(sys.argv[1]))['browser'].get('clearReport') or 'no report')" "$t/state.json"
    quit
    rm -rf "$t"
  fi
  rm -rf "$app" "$data" "$HOME/Library/WebKit/$id" "$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id" \
         "$HOME/Library/Saved Application State/$id.savedState"
  defaults delete "$id" 2> /dev/null || true
  for d in "$app" "$data" "$HOME/Library/WebKit/$id"; do [[ -e "$d" ]] && echo "still there: $d"; done
  echo "Video Buddy 4.0 Preview removed (Video Buddy 3.1 untouched)"
  exit 0
fi

git merge-base --is-ancestor 886ee64 HEAD || { echo "this checkout doesn't contain 886ee64 (4.0 Phase 1b)"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
b="$tmp/$name.app"
plist="$b/Contents/Info.plist"
mkdir -p "$b/Contents/MacOS" "$b/Contents/Resources/raycast" "$tmp/AppIcon.iconset"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 $(find Sources -name '*.swift' | sort) -o "$b/Contents/MacOS/$exe"
cp Info.plist "$plist"
for kv in "CFBundleIdentifier=$id" "CFBundleName=$name" "CFBundleDisplayName=$name" "CFBundleExecutable=$exe" \
          "CFBundleShortVersionString=4.0" "CFBundleVersion=6" "VBCommit=$(git rev-parse --short HEAD)"; do
  plutil -replace "${kv%%=*}" -string "${kv#*=}" "$plist"
done
plutil -replace VBPreview -bool YES "$plist"
cp -Rp ../scripts "$b/Contents/Resources/scripts"
cp -p ../raycast/summarize.sh "$b/Contents/Resources/raycast/"

# inside the bundle, so the preview checks run too (own data folder, downloads inside it, queue locked)
"$b/Contents/MacOS/$exe" --selftest

swift make-icon.swift "$tmp/icon.png" preview
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$b/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$b"

quit
rm -rf "$app"
mv "$b" "$app"
defaults write "$id" queuePaused -bool true
if [[ -n $test ]]; then echo "Test build: $app ($id)"; exit 0; fi
mkdir -p "$data/Downloads"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed $app ($(git rev-parse --short HEAD)). Open it from Finder → Applications, or Spotlight: \"Video Buddy 4.0\""
