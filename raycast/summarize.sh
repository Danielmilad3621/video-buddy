#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Summarize Video
# @raycast.mode fullOutput
# @raycast.packageName cobalt
# @raycast.icon 🧠
# @raycast.argument1 { "type": "text", "placeholder": "URL (blank = clipboard)", "optional": true }
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"   # Raycast doesn't load your shell profile
url=${1:-$(pbpaste)}

echo "⬇️  Downloading audio…"
mp3=$("$HOME/cobalt/cobalt-dl.sh" "$url" audio "$HOME/Downloads/cobalt")
base=${mp3%.*}

echo "🎙️  Transcribing on-device…"
log="${TMPDIR:-/tmp}/cobalt-whisper-$$.log"
trap 'rm -f "$log"' EXIT
# whisper-cli prints its GPU init chatter on stderr, so only show it if transcription fails
whisper-cli -np -l auto -m "$HOME/.config/watch/models/ggml-large-v3-turbo-q5_0.bin" \
  -f "$mp3" -otxt -of "$base.transcript" > /dev/null 2> "$log" || { cat "$log"; exit 1; }

echo "🧠 Summarizing…"; echo
claude -p --model sonnet "Summarize this video transcript. Start with a 3-sentence TL;DR, then the key points as bullets, then any actionable takeaways." \
  < "$base.transcript.txt" | tee "$base.summary.md"
echo; echo "📁 $mp3"
