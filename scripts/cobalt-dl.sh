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
  echo "Playlist link: paste it into the Video Buddy app to pick videos" >&2
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

quality=${VS_VIDEO_QUALITY:-}   # 480 | 720 | 1080 | max | highest from the app's setting; unset = the defaults, exactly as before
# cobalt has no AV1 choice: for other sites, highest is its max
body=$(jq -n --arg url "$url" --arg mode "$mode" --arg q "${quality/#highest/max}" \
  '{url: $url, downloadMode: $mode, audioFormat: "mp3", audioBitrate: "128", filenameStyle: "pretty"} + (if $q != "" then {videoQuality: $q} else {} end)')
# 4.0 G1b: YouTube goes straight to yt-dlp. cobalt answers "tunnel" for YouTube but streams nothing (HTTP 200, 0 bytes,
# measured in G1a and G1b; upstream imputnet/cobalt#1455), so asking it first only costs time. Other sites still try cobalt.
shopt -s nocasematch
if [[ $url =~ ^https?://([a-z0-9-]+\.)*(youtube\.com|youtu\.be|youtube-nocookie\.com)([/?#]|$) ]]; then
  resp='{}'; reason=youtube
else
  resp=$(curl -sS --max-time 60 http://localhost:9000/ \
    -H 'Accept: application/json' -H 'Content-Type: application/json' -d "$body" 2>/dev/null) || resp='{}'
  reason=$(jq -r '.error.code // .status // "unreachable"' <<<"$resp" 2>/dev/null) || reason=unreachable
fi
shopt -u nocasematch

if [[ $reason == tunnel || $reason == redirect ]]; then
  name=$(jq -r .filename <<<"$resp")
  name=${name//\//_}
  # an empty file means the source refused the stream, so treat it as a failure too
  got=$(curl -fsSL -o "$tmp/$name" -w '%{http_code} %{size_download}' "$(jq -r .url <<<"$resp")" 2> "$tmp/curl.err") && code=0 || code=$?
  if [[ $code == 0 && -s $tmp/$name ]]; then
    place "$tmp/$name"
    exit 0
  fi
  rm -f "$tmp/$name"
  # what actually happened, for the job's log (4.0 G1b)
  reason="$reason, but its download failed (HTTP ${got%% *}, ${got##* } bytes, curl exit $code$(head -c 200 "$tmp/curl.err" | tr '\n' ' ' | sed 's/^curl/: curl/'))"
fi

if [[ $reason == youtube ]]; then
  echo "yt-dlp: a YouTube link, so straight to yt-dlp (cobalt's YouTube downloads come back empty)" >&2
else
  echo "cobalt: $reason, falling back to yt-dlp" >&2
fi
if [[ $mode == audio ]]; then
  fmt=(-x --audio-format mp3 --audio-quality 128K)   # a fixed 128 kbit/s, like cobalt's, so sizes are predictable
else
  fmt=(-t mp4)
  # keep -t mp4's H.264/AAC preference (plays everywhere, including the app's player) and cap the height
  if [[ $quality =~ ^[0-9]+$ ]]; then fmt+=(-S "vcodec:h264,res:$quality,acodec:aac"); fi
  # 4.0 G2, Highest available: the highest AV1 stream (YouTube's 1440p and 4K), else H.264, with AAC, in MP4; never VP9,
  # which AVFoundation doesn't reliably play. The app offers it only where AV1 decodes in hardware.
  if [[ $quality == highest ]]; then
    fmt=(-f 'bv*[vcodec^=av01]+ba[acodec^=mp4a]/bv*[vcodec^=avc1]+ba[acodec^=mp4a]/b' -S res --merge-output-format mp4 --remux-video mp4)
  fi
fi
# 4.0 G1b-2, test runs only: a speed limit so a download can be interrupted on purpose. The app passes these two
# variables only to an isolated build (RC or Preview) started with test hooks, and removes them otherwise.
if [[ ${VS_TEST_RUN:-} == 1 && -n ${VS_TEST_LIMIT_RATE:-} ]]; then fmt+=(--limit-rate "$VS_TEST_LIMIT_RATE"); fi
# ponytail: youtube 403s ~1 in 6 tries without a PO token, and a fresh extraction usually passes;
# if retries stop being enough, add the bgutil-ytdlp-pot-provider plugin
for attempt in 1 2 3; do
  # 4.0 G2: the streams yt-dlp chose go into the job's log (first line), the saved file's path stays the last
  if got=$(yt-dlp -q --no-warnings --no-playlist "${fmt[@]}" -P "$tmp/dl" -o '%(title)s.%(ext)s' \
    --print 'before_dl:yt-dlp: format %(format_id)s (%(resolution)s, %(vcodec)s + %(acodec)s)' --print after_move:filepath -- "$url") \
    && file=${got##*$'\n'} && [[ -s $file ]]; then
    echo "${got%%$'\n'*}" >&2
    place "$file"
    exit 0
  fi
  rm -rf "$tmp/dl"
  echo "yt-dlp attempt $attempt failed" >&2
done
exit 1
