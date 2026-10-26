#!/bin/bash
# builds, self-tests and installs ~/Applications/Video Buddy.app (re-run after editing Sources/ or the scripts)
# 4.0: an existing app is never deleted. Replacing one needs VB_BACKUP_SET=<folder>, a backup set that
# app/tools/backup-before-4.0.sh --verify accepts, and the app must not be running. The existing app is moved aside
# as "Video Buddy <its version>.app.disabled" (macOS no longer sees it as an app) and put back if the install fails.
# VB_INSTALL_DIR installs somewhere else (the rehearsal: a temporary "Applications" folder).
set -euo pipefail
cd "$(dirname "$0")"
dir=${VB_INSTALL_DIR:-$HOME/Applications}
app="$dir/Video Buddy.app"
[[ ! -e $app.partial ]] || { echo "refused: $app.partial already exists; it was kept"; exit 2; }
if [[ -e $app ]]; then
  [[ -n ${VB_BACKUP_SET:-} ]] || { echo "refused: $app exists; replacing it needs VB_BACKUP_SET=<a verified backup set> (app/tools/backup-before-4.0.sh)"; exit 2; }
  tools/backup-before-4.0.sh --verify "$VB_BACKUP_SET" || { echo "refused: the backup set didn't verify; nothing was changed"; exit 2; }
  exe=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")
  code=0; pgrep -f "^$app/Contents/MacOS/$exe" > /dev/null || code=$?
  [[ $code == 1 ]] || { echo "refused: $app is running or its process status could not be checked (exit $code); quit it first"; exit 2; }
fi
tmp=$(mktemp -d)
cleanup() { if [[ ${VB_KEEP_TEST_FILES:-} == 1 ]]; then echo "Build files retained: $tmp"; else rm -rf "$tmp"; fi; }
trap cleanup EXIT
bundle="$tmp/VideoSummarizer.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$tmp/AppIcon.iconset"

swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  $(find Sources -name '*.swift' | sort) -o "$bundle/Contents/MacOS/VideoSummarizer"

# the app runs its own copy of the pipeline scripts (same layout as the project), so it never depends on
# where this folder lives; edit the scripts here, then rebuild for the app to pick them up
cp Info.plist "$bundle/Contents/"
plutil -replace VBCommit -string "$(git rev-parse --short HEAD)" "$bundle/Contents/Info.plist"
mkdir -p "$bundle/Contents/Resources/raycast"
cp -Rp ../scripts "$bundle/Contents/Resources/scripts"
cp -p ../raycast/summarize.sh "$bundle/Contents/Resources/raycast/"

# Run the identical binary with an isolated identity; never run test hooks on production.
test_bundle="$tmp/Video Buddy Build Test.app"
ditto "$bundle" "$test_bundle"
plutil -replace CFBundleIdentifier -string local.video-summarizer.preview-test "$test_bundle/Contents/Info.plist"
plutil -replace CFBundleName -string 'Video Buddy 4.0 Test' "$test_bundle/Contents/Info.plist"
plutil -replace VBPreview -bool YES "$test_bundle/Contents/Info.plist"
VS_KEEP_TEST_FILES="${VB_KEEP_TEST_FILES:-0}" "$test_bundle/Contents/MacOS/VideoSummarizer" --selftest

swift make-icon.swift "$tmp/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$bundle"
built_hash=$(shasum -a 256 "$bundle/Contents/MacOS/VideoSummarizer" | awk '{print $1}')
mkdir -p "$dir"
aside=
if [[ -e $app ]]; then
  code=0; pgrep -f "^$app/Contents/MacOS/$exe" > /dev/null || code=$?
  [[ $code == 1 ]] || { echo "refused: $app started during the build or its process status could not be checked"; exit 2; }
  aside="$dir/Video Buddy $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist").app.disabled"
  [[ -e $aside ]] && aside="${aside%.app.disabled}-$(date +%Y%m%d-%H%M%S).app.disabled"
  mv "$app" "$aside"
  echo "Moved the existing app aside: $aside"
fi
# put the old app back if anything below fails (the rehearsal can make it fail on purpose, never in ~/Applications)
restore() {
  if [[ -e $app.partial ]]; then
    if [[ ${VB_KEEP_TEST_FILES:-} == 1 ]]; then mv "$app.partial" "$tmp/failed-install.app.partial"; else rm -rf "$app.partial"; fi
  fi
  if [[ -n $aside && ! -e $app ]]; then mv "$aside" "$app" && echo "Install failed: put the previous app back ($app)"; fi
}
trap 'restore; cleanup' EXIT
mv "$bundle" "$app.partial"
[[ ${VB_REHEARSE_FAILURE:-} == 1 && $dir != "$HOME/Applications" ]] && { echo "rehearsal: failing on purpose"; exit 1; }
codesign --verify --deep --strict "$app.partial"
installed_hash=$(shasum -a 256 "$app.partial/Contents/MacOS/VideoSummarizer" | awk '{print $1}')
[[ $installed_hash == "$built_hash" ]] || { echo "refused: executable changed while being installed"; exit 2; }
mv "$app.partial" "$app"
trap cleanup EXIT
echo "Installed $app$([[ -n $aside ]] && echo "; the previous app is $aside (to roll back: quit Video Buddy, rename this one aside, rename that one back to Video Buddy.app)")"
