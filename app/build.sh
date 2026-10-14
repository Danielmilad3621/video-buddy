#!/bin/bash
# builds and installs ~/Applications/Video Summarizer.app from this folder (re-run after editing the .swift)
set -euo pipefail
cd "$(dirname "$0")"
app="$HOME/Applications/Video Summarizer.app"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bundle="$tmp/VideoSummarizer.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$tmp/AppIcon.iconset"

swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  VideoSummarizer.swift -o "$bundle/Contents/MacOS/VideoSummarizer"
cp Info.plist "$bundle/Contents/"

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
