#!/bin/bash
# builds, self-tests and installs ~/Applications/Video Summarizer.app (re-run after editing Sources/ or the scripts)
set -euo pipefail
cd "$(dirname "$0")"
app="$HOME/Applications/Video Summarizer.app"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bundle="$tmp/VideoSummarizer.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$tmp/AppIcon.iconset"

swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  $(find Sources -name '*.swift' | sort) -o "$bundle/Contents/MacOS/VideoSummarizer"

# the app runs its own copy of the pipeline scripts (same layout as the project), so it never depends on
# where this folder lives; edit the scripts here, then rebuild for the app to pick them up
cp Info.plist "$bundle/Contents/"
mkdir -p "$bundle/Contents/Resources/raycast"
cp -Rp ../scripts "$bundle/Contents/Resources/scripts"
cp -p ../raycast/summarize.sh "$bundle/Contents/Resources/raycast/"

# never install a build whose core logic is broken
"$bundle/Contents/MacOS/VideoSummarizer" --selftest

swift make-icon.swift "$tmp/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$bundle"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mv "$bundle" "$app"
echo "Installed $app"
