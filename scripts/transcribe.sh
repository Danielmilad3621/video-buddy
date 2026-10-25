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

# 4.0 G2: the language, from three 30-second windows at 10%, 40% and 70% of the length, by majority (the middle one if
# all three differ). whisper.cpp decides from the first 30 s only, so a music intro could pick the wrong language, and
# its -ot doesn't move that, hence the cuts. 30 s or shorter, or not three answers: -l auto, as before.
lang=auto votes=()
length=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$input" 2> /dev/null | cut -d. -f1 || true)
if [[ $length =~ ^[0-9]+$ ]] && ((length > 30)); then
  for pct in 10 40 70; do
    ffmpeg -nostdin -loglevel error -y -ss $((length * pct / 100)) -t 30 -i "$input" -ac 1 -ar 16000 -c:a pcm_s16le "$tmp/window.wav" || continue
    v=$(whisper-cli -dl -m "$model" -f "$tmp/window.wav" 2>&1 | sed -n 's/.*auto-detected language: \([a-z]*\) (p = \([0-9.]*\)).*/\1 \2/p' | tail -1 || true)
    [[ -n $v ]] && votes+=("$v")
  done
  if ((${#votes[@]} == 3)); then
    a=${votes[0]%% *} b=${votes[1]%% *} c=${votes[2]%% *}
    if [[ $a == "$b" || $a == "$c" ]]; then lang=$a; else lang=$b; fi
  fi
  echo "Language: $lang (at 10%, 40%, 70%: ${votes[*]+$(IFS=,; echo "${votes[*]}")})" >&2
fi

# whisper-cli prints its GPU start-up chatter on stderr, so it goes to a log that's shown only on failure.
# The output is written in the temp dir and moved next to the media only when complete.
whisper-cli -np -l "$lang" -m "$model" -f "$input" -otxt -oj -of "$tmp/t" > /dev/null 2> "$tmp/log" || { cat "$tmp/log"; exit 1; }
# the votes go into the JSON too (kept as it is if that fails)
if ((${#votes[@]})); then
  jq --args '. + {languageVotes: $ARGS.positional}' "${votes[@]}" < "$tmp/t.json" > "$tmp/v.json" 2> /dev/null && mv "$tmp/v.json" "$tmp/t.json" || true
fi
[[ -e $base.transcript.json ]] || mv "$tmp/t.json" "$base.transcript.json"
mv "$tmp/t.txt" "$base.transcript.txt"
echo "$base.transcript.txt"
