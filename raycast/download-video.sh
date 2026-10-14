#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Download Video (mp4)
# @raycast.mode compact
# @raycast.packageName cobalt
# @raycast.icon 🎬
# @raycast.argument1 { "type": "text", "placeholder": "URL (blank = clipboard)", "optional": true }
set -euo pipefail
url=${1:-$(pbpaste)}
file=$("$HOME/cobalt/cobalt-dl.sh" "$url" auto "$HOME/Downloads/cobalt")
echo "Saved $(basename "$file")"
