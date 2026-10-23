#!/bin/bash
# send-to-app.sh <video|audio|summarize> <url>: 4.0. Raycast never downloads a YouTube link itself: it hands the link to
# Video Buddy (videobuddy://request), which shows it for you to confirm, then runs the same checks as everywhere else.
# If that app isn't a 4.0 build (it doesn't handle videobuddy://), this stops instead of downloading.
#   send-to-app.sh --is-youtube <url>   exit 0 for a YouTube link (the caller hands it over), 1 for anything else
# VB_BUNDLE_ID picks the app (default: Video Buddy, local.video-summarizer); tests point it at the RC, or VB_APP at an
# app by its path (a test build in a temporary folder, which macOS doesn't look up by bundle ID).
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
shopt -s nocasematch
youtube='^https?://([a-z0-9-]+\.)*(youtube\.com|youtu\.be|youtube-nocookie\.com)([/?#]|$)'
if [[ $1 == --is-youtube ]]; then [[ ${2:-} =~ $youtube ]]; exit; fi

action=$1 url=$2
id=${VB_BUNDLE_ID:-local.video-summarizer}
[[ $action =~ ^(video|audio|summarize)$ && $url =~ $youtube ]] || { echo "usage: send-to-app.sh <video|audio|summarize> <YouTube link>" >&2; exit 2; }
# where macOS would open that app from (nothing is launched to find out), and whether it handles videobuddy://
app=${VB_APP:-$(osascript -l JavaScript -e "ObjC.import('AppKit'); const u = \$.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier('$id'); u.isNil() ? '' : u.path.js" 2> /dev/null || true)}
if [[ -z $app ]] || ! plutil -extract CFBundleURLTypes xml1 -o - "$app/Contents/Info.plist" 2> /dev/null | grep -q '<string>videobuddy</string>'; then
  echo "Video Buddy 4.0 isn't installed, so nothing was downloaded: open the link in the Video Buddy app." >&2
  exit 1
fi
# opened with exactly the app checked above
open -a "$app" "videobuddy://request?action=$action&url=$(jq -rn --arg u "$url" '$u | @uri')"
echo "Sent to $(basename "$app" .app): confirm it there."
