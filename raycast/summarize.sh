#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Summarize Video
# @raycast.mode fullOutput
# @raycast.packageName cobalt
# @raycast.icon 🧠
# @raycast.argument1 { "type": "text", "placeholder": "URL (blank = clipboard)", "optional": true }
# Video Summarizer.app runs this too; it sets VS_FROM_APP, VS_OUT_DIR and VS_SUMMARY_PROMPT.
# the marker lines below (Downloading / Transcribing / Summarizing / 📁) are parsed by the app: keep them stable.
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"   # Raycast doesn't load your shell profile
url=${1:-$(pbpaste)}
out=${VS_OUT_DIR:-$HOME/Downloads/cobalt}
prompt=${VS_SUMMARY_PROMPT:-"Summarize this video transcript. Start with a 3-sentence TL;DR, then the key points as bullets, then any actionable takeaways."}
log="${TMPDIR:-/tmp}/cobalt-whisper-$$.log"
base=""
trap 'rm -f "$log"; if [[ -n $base ]]; then rm -f "$base.summary.md.part"; fi' EXIT
trap 'exit 143' TERM INT

echo "⬇️  Downloading audio…"
mp3=$("$HOME/cobalt/cobalt-dl.sh" "$url" audio "$out")
base=${mp3%.*}

echo "🎙️  Transcribing on-device…"
# whisper-cli prints its GPU init chatter on stderr, so only show it if transcription fails.
# -oj adds <base>.transcript.json (timestamped segments + detected language) next to the .txt
whisper-cli -np -l auto -m "$HOME/.config/watch/models/ggml-large-v3-turbo-q5_0.bin" \
  -f "$mp3" -otxt -oj -of "$base.transcript" > /dev/null 2> "$log" || { cat "$log"; exit 1; }

echo "🧠 Summarizing…"; echo
# written to .part first, so a failed or cancelled run never leaves an empty or half summary behind
claude -p --model sonnet "$prompt" < "$base.transcript.txt" | tee "$base.summary.md.part"
mv "$base.summary.md.part" "$base.summary.md"
[[ -n ${VS_FROM_APP:-} ]] || "$HOME/cobalt/record-history.sh" summary "$url" "$mp3" || true
echo; echo "📁 $mp3"
