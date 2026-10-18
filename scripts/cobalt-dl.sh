#!/bin/bash
# cobalt-dl.sh <url> <audio|auto> <out-dir>
# saves the media through the local cobalt API (falls back to yt-dlp) and prints the saved file's path.
# downloads land in a private temp dir first, so a cancelled or failed run never leaves partial files,
# and the result gets a fresh name, so an existing mp3, summary or transcript is never overwritten.
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
url=$1 mode=$2 out=$3
# a playlist link with no single video in it would make yt-dlp download the whole list: those belong in the app
if [[ $url =~ (youtube\.com|youtu\.be)/.*[?\&]list= && ! $url =~ ([?\&]v=|youtu\.be/|/shorts/|/live/)[A-Za-z0-9_-]{11} ]]; then
  echo "Playlist link: paste it into the Video Summarizer app to pick videos" >&2
  exit 2
fi
mkdir -p "$out"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cobalt-dl.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 143' TERM INT

# true if this stem is used by an earlier download or its summary/transcript files
taken() {
  local s="$out/$1"
  [[ -e $s.$2 || -e $s.summary.md || -e $s.summary.md.part || -e $s.transcript.txt || -e $s.transcript.json ]]
}

# move a finished download into $out under a free name and print the final path
place() {
  local name=${1##*/} n=2
  local stem=${name%.*} ext=${name##*.}
  local dest=$stem
  while taken "$dest" "$ext"; do dest="$stem ($n)"; n=$((n + 1)); done
  mv "$1" "$out/$dest.$ext"
  echo "$out/$dest.$ext"
}

quality=${VS_VIDEO_QUALITY:-}   # 720 | 1080 | max from the app's setting; unset = the defaults, exactly as before
body=$(jq -n --arg url "$url" --arg mode "$mode" --arg q "$quality" \
  '{url: $url, downloadMode: $mode, audioFormat: "mp3", filenameStyle: "pretty"} + (if $q != "" then {videoQuality: $q} else {} end)')
resp=$(curl -sS --max-time 60 http://localhost:9000/ \
  -H 'Accept: application/json' -H 'Content-Type: application/json' -d "$body" 2>/dev/null) || resp='{}'
reason=$(jq -r '.error.code // .status // "unreachable"' <<<"$resp" 2>/dev/null) || reason=unreachable

if [[ $reason == tunnel || $reason == redirect ]]; then
  name=$(jq -r .filename <<<"$resp")
  name=${name//\//_}
  # an empty file means the source refused the stream, so treat it as a failure too
  if curl -fsSL -o "$tmp/$name" "$(jq -r .url <<<"$resp")" && [[ -s $tmp/$name ]]; then
    place "$tmp/$name"
    exit 0
  fi
  rm -f "$tmp/$name"
  reason="tunnel download failed"
fi

echo "cobalt: $reason, falling back to yt-dlp" >&2
if [[ $mode == audio ]]; then
  fmt=(-x --audio-format mp3)
else
  fmt=(-t mp4)
  # keep -t mp4's H.264/AAC preference (plays everywhere, including the app's player) and cap the height
  if [[ $quality =~ ^[0-9]+$ ]]; then fmt+=(-S "vcodec:h264,res:$quality,acodec:aac"); fi
fi
# ponytail: youtube 403s ~1 in 6 tries without a PO token, and a fresh extraction usually passes;
# if retries stop being enough, add the bgutil-ytdlp-pot-provider plugin
for attempt in 1 2 3; do
  if file=$(yt-dlp -q --no-warnings --no-playlist "${fmt[@]}" -P "$tmp/dl" -o '%(title)s.%(ext)s' \
    --print after_move:filepath -- "$url") && [[ -s $file ]]; then
    place "$file"
    exit 0
  fi
  rm -rf "$tmp/dl"
  echo "yt-dlp attempt $attempt failed" >&2
done
exit 1
