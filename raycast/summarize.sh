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
# 4.0: from Raycast, a YouTube link goes to Video Buddy, which asks you and runs its checks (the app runs this script
# itself for its own summaries, with VS_FROM_APP set, after those checks)
if [[ -z ${VS_FROM_APP:-} ]] && "$root/scripts/send-to-app.sh" --is-youtube "$url"; then exec "$root/scripts/send-to-app.sh" summarize "$url"; fi
# 4.0: AI summaries are off until you allow them (Video Buddy → Settings → Summaries). The app passes its own setting;
# from Raycast the same setting is read here. Off: nothing is downloaded and nothing is sent.
if [[ -z ${VS_FROM_APP:-} ]]; then
  [[ $(defaults read local.video-summarizer aiSummariesApproved 2> /dev/null) == 1 ]] && export VS_AI_APPROVED=1
fi
if [[ ${VS_AI_APPROVED:-} != 1 ]]; then
  echo "AI summaries are off (Video Buddy → Settings → Summaries → Allow AI summaries). Nothing was downloaded or sent." >&2
  exit 3
fi
out=${VS_OUT_DIR:-$HOME/Downloads/cobalt}
downloader="$root/scripts/cobalt-dl.sh"
[[ ${VS_TEST_RUN:-} == 1 && -n ${VS_TEST_DOWNLOADER:-} ]] && downloader=$VS_TEST_DOWNLOADER   # test runs only
prompt=${VS_SUMMARY_PROMPT:-"Summarize this video transcript. Start with a 3-sentence TL;DR, then the key points as bullets, then any actionable takeaways."}
base=""
trap 'if [[ -n $base ]]; then rm -f "$base.summary.md.part"; fi' EXIT
trap 'exit 143' TERM INT

echo "⬇️  Downloading audio…"
mp3=$("$downloader" "$url" audio "$out" | tail -n 1)   # the saved file's path is its last line
base=${mp3%.*}

# transcribe.sh prints the 🎙️ marker itself and writes <base>.transcript.txt/.json; its last line (the path) isn't shown
"$root/scripts/transcribe.sh" "$mp3" | grep --line-buffered -v '^/'

echo "🧠 Summarizing…"; echo
# 4.0: the one paid request, through ai-summary.sh (Haiku 5.5, at most $1, no retry; it writes the summary only on
# success, via .part, and prints the model, cost and tokens)
"$root/scripts/ai-summary.sh" "$prompt" "$base.transcript.txt" "$base.summary.md"
cat "$base.summary.md"
[[ -n ${VS_FROM_APP:-} ]] || "$root/scripts/record-history.sh" summary "$url" "$mp3" || true
echo; echo "📁 $mp3"
