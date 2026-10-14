#!/bin/bash
# record-history.sh <summary|audio|video> <url> <file>
# appends one event to Video Summarizer's inbox; the app ingests it whenever it runs, so this never needs the app
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
dir=${VS_DATA_DIR:-"$HOME/Library/Application Support/Video Summarizer"}
inbox="$dir/inbox.jsonl"
mkdir -p "$dir" || exit 0

# jq -c: always valid JSON on one line, whatever is in the title or URL
line=$(jq -nc --arg id "$(uuidgen)" --arg kind "$1" --arg url "$2" --arg file "$3" \
  '{id: $id, kind: $kind, url: $url, file: $file, at: now}') || exit 0

# one locked write per event, so parallel Raycast runs can't interleave lines
/usr/bin/lockf -k -t 5 "$inbox.lock" /bin/sh -c 'printf "%s\n" "$1" >> "$2"' sh "$line" "$inbox" || true
