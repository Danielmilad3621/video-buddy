#!/bin/bash
# Offline, retained tests. No UI launch, settings writes, downloads, AI, registration or cleanup.
# Optional argument: an already-captured yt-dlp JSON response (never fetched here).
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vb-format-test.XXXXXX")
echo "Test files retained in: $T"
app="$T/Video Buddy Format Test.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/raycast"
cp "$repo/app/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.video-summarizer.preview-test "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string VideoBuddyTest "$app/Contents/Info.plist"
plutil -replace CFBundleName -string 'Video Buddy 4.0 Test' "$app/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string 'Video Buddy Format Test' "$app/Contents/Info.plist"
plutil -replace VBPreview -bool YES "$app/Contents/Info.plist"
cp -Rp "$repo/scripts" "$app/Contents/Resources/scripts"
cp -p "$repo/raycast/summarize.sh" "$app/Contents/Resources/raycast/"
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find "$repo/app/Sources" -name '*.swift' | sort)
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$T/module-cache" "${sources[@]}" -o "$app/Contents/MacOS/VideoBuddyTest" > "$T/build.log" 2>&1 \
  || { cat "$T/build.log"; exit 1; }
codesign --force --sign - "$app"
"$app/Contents/MacOS/VideoBuddyTest" --selftest-formats "$@" | tee "$T/swift-tests.log"
# Use the Python environment belonging to the installed Homebrew yt-dlp, without installing anything.
python=$(python3 -c 'import pathlib; print(pathlib.Path("/opt/homebrew/bin/yt-dlp").resolve().with_name("python"))')
PYTHONDONTWRITEBYTECODE=1 "$python" "$repo/app/tests/format-selection-test.py" "$repo" "$T" "${1:-}" | tee "$T/selector-tests.log"
