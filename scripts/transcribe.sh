#!/bin/bash
# transcribe.sh <audio or video file>
# on-device transcript with whisper.cpp; works without internet. Writes <base>.transcript.txt and
# <base>.transcript.json (timestamped segments + detected language) next to the file and prints the .txt path as
# its last line. Existing transcript files are reused, never overwritten. Prints the same 🎙️ marker as summarize.sh.
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
media=$1
base=${media%.*}
model=${VS_WHISPER_MODEL:-$HOME/.config/watch/models/ggml-large-v3-turbo-q5_0.bin}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/transcribe.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 143' TERM INT

[[ -s $media ]] || { echo "No such file: $media" >&2; exit 1; }
echo "🎙️  Transcribing on-device…"
if [[ -s $base.transcript.txt ]]; then
  echo "Reusing the transcript that's already next to this file" >&2
  echo "$base.transcript.txt"
  exit 0
fi

input=$media
case "$(tr '[:upper:]' '[:lower:]' <<<"${media##*.}")" in
  mp3|wav|flac|ogg) ;;   # whisper.cpp decodes these itself
  *) ffmpeg -nostdin -loglevel error -i "$media" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$tmp/audio.wav"
     input=$tmp/audio.wav ;;
esac

# whisper-cli prints its GPU start-up chatter on stderr, so it goes to a log that's shown only on failure.
# The output is written in the temp dir and moved next to the media only when complete.
whisper-cli -np -l auto -m "$model" -f "$input" -otxt -oj -of "$tmp/t" > /dev/null 2> "$tmp/log" || { cat "$tmp/log"; exit 1; }
[[ -e $base.transcript.json ]] || mv "$tmp/t.json" "$base.transcript.json"
mv "$tmp/t.txt" "$base.transcript.txt"
echo "$base.transcript.txt"
