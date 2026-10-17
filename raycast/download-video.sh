#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Download Video (mp4)
# @raycast.mode compact
# @raycast.packageName cobalt
# @raycast.icon 🎬
# @raycast.argument1 { "type": "text", "placeholder": "URL (blank = clipboard)", "optional": true }
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # the project folder; works wherever it lives
url=${1:-$(pbpaste)}
file=$("$root/scripts/cobalt-dl.sh" "$url" auto "$HOME/Downloads/cobalt")
"$root/scripts/record-history.sh" video "$url" "$file" || true   # Video Summarizer history
echo "Saved $(basename "$file")"
