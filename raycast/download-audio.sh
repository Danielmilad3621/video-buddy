#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Download Audio (mp3)
# @raycast.mode compact
# @raycast.packageName cobalt
# @raycast.icon 🎵
# @raycast.argument1 { "type": "text", "placeholder": "URL (blank = clipboard)", "optional": true }
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # the project folder; works wherever it lives
url=${1:-$(pbpaste)}
# 4.0: a YouTube link goes to Video Buddy, which asks you and runs its checks; Raycast never downloads one itself
if "$root/scripts/send-to-app.sh" --is-youtube "$url"; then exec "$root/scripts/send-to-app.sh" audio "$url"; fi
file=$("$root/scripts/cobalt-dl.sh" "$url" audio "${VS_OUT_DIR:-$HOME/Downloads/cobalt}")
"$root/scripts/record-history.sh" audio "$url" "$file" || true   # Video Summarizer history
echo "Saved $(basename "$file")"
