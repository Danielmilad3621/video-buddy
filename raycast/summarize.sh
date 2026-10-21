#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Summarize Video
# @raycast.mode fullOutput
# @raycast.packageName cobalt
# @raycast.icon 🧠
# @raycast.argument1 { "type": "text", "placeholder": "URL (blank = clipboard)", "optional": true }
# Video Buddy.app runs its own bundled copy of this (rebuild the app after editing); it sets VS_FROM_APP, VS_OUT_DIR and VS_SUMMARY_PROMPT.
# the marker lines below (Downloading / Transcribing / Summarizing / 📁) are parsed by the app: keep them stable.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # the project folder; works wherever it lives
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"   # Raycast doesn't load your shell profile
url=${1:-$(pbpaste)}
out=${VS_OUT_DIR:-$HOME/Downloads/cobalt}
prompt=${VS_SUMMARY_PROMPT:-"Summarize this video transcript. Start with a 3-sentence TL;DR, then the key points as bullets, then any actionable takeaways."}
base=""
trap 'if [[ -n $base ]]; then rm -f "$base.summary.md.part"; fi' EXIT
trap 'exit 143' TERM INT

echo "⬇️  Downloading audio…"
mp3=$("$root/scripts/cobalt-dl.sh" "$url" audio "$out")
base=${mp3%.*}

# transcribe.sh prints the 🎙️ marker itself and writes <base>.transcript.txt/.json; its last line (the path) isn't shown
"$root/scripts/transcribe.sh" "$mp3" | grep --line-buffered -v '^/'

echo "🧠 Summarizing…"; echo
# written to .part first, so a failed or cancelled run never leaves an empty or half summary behind
claude -p --model sonnet "$prompt" < "$base.transcript.txt" | tee "$base.summary.md.part"
mv "$base.summary.md.part" "$base.summary.md"
[[ -n ${VS_FROM_APP:-} ]] || "$root/scripts/record-history.sh" summary "$url" "$mp3" || true
echo; echo "📁 $mp3"
