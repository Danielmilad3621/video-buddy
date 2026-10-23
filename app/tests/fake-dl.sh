#!/bin/bash
# fake-dl.sh <url> <audio|auto> <out-dir>: the test build's stand-in for scripts/cobalt-dl.sh (only "Video Buddy 4.0 Test"
# with VS_TEST_FAKE_DOWNLOADS uses it). It never touches the network: it copies a sample clip, finishing the way the
# real script does (put together in a temporary folder, then moved into place, never over an existing file), and prints
# the saved path. What a video does comes from the control file $VS_FAKE_CONTROL ("<id> <ok|fail|hang|slow|nospace-final>").
set -euo pipefail
url=$1 mode=$2 out=$3
id=$(sed -nE 's/.*[?&]v=([A-Za-z0-9_-]{11}).*/\1/p' <<<"$url")
what=$(grep -E "^$id " "${VS_FAKE_CONTROL:-/dev/null}" 2>/dev/null | tail -1 | cut -d' ' -f2 || true)
what=${what:-ok}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 143' TERM INT
echo "fake: $id $mode quality=${VS_VIDEO_QUALITY:-setting} ($what)"
steps=4; [[ $what == slow ]] && steps=24
for i in $(seq 1 "$steps"); do
  echo "[download] $((i * 100 / steps))% (fake)"
  head -c 200000 /dev/zero > "$tmp/part.$i"       # it grows while it "downloads", like a real one
  sleep 0.25
done
case $what in
  fail) echo "ERROR: fake failure for $id" >&2; exit 1 ;;
  hang) sleep 3600 ;;
  nospace-final) echo "mv: $out: No space left on device (fake)" >&2; exit 1 ;;
esac
ext=mp4; [[ $mode == audio ]] && ext=mp3
cp "$VS_FAKE_SAMPLES/sample.$ext" "$tmp/done.$ext"
dest="$out/fake $id.$ext"; n=2
while [[ -e $dest ]]; do dest="$out/fake $id ($n).$ext"; n=$((n + 1)); done
mv "$tmp/done.$ext" "$dest"
echo "$dest"
