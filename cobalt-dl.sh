#!/bin/bash
# cobalt-dl.sh <url> <audio|auto> <out-dir>
# saves the media through the local cobalt API (falls back to yt-dlp) and prints the saved file's path
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
url=$1 mode=$2 out=$3
mkdir -p "$out"

body=$(jq -n --arg url "$url" --arg mode "$mode" \
  '{url: $url, downloadMode: $mode, audioFormat: "mp3", filenameStyle: "pretty"}')
resp=$(curl -sS --max-time 60 http://localhost:9000/ \
  -H 'Accept: application/json' -H 'Content-Type: application/json' -d "$body" 2>/dev/null) || resp='{}'
reason=$(jq -r '.error.code // .status // "unreachable"' <<<"$resp" 2>/dev/null) || reason=unreachable

if [[ $reason == tunnel || $reason == redirect ]]; then
  file="$out/$(jq -r .filename <<<"$resp")"
  # an empty file means the source refused the stream, so treat it as a failure too
  if curl -fsSL -o "$file" "$(jq -r .url <<<"$resp")" && [[ -s $file ]]; then
    echo "$file"
    exit 0
  fi
  rm -f "$file"
  reason="tunnel download failed"
fi

echo "cobalt: $reason, falling back to yt-dlp" >&2
if [[ $mode == audio ]]; then fmt=(-x --audio-format mp3); else fmt=(-t mp4); fi
# ponytail: youtube 403s ~1 in 6 tries without a PO token, and a fresh extraction usually passes;
# if retries stop being enough, add the bgutil-ytdlp-pot-provider plugin
for attempt in 1 2 3; do
  yt-dlp -q --no-warnings --no-playlist "${fmt[@]}" -P "$out" -o '%(title)s.%(ext)s' \
    --print after_move:filepath -- "$url" && exit 0
  echo "yt-dlp attempt $attempt failed" >&2
done
exit 1
