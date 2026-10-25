#!/bin/bash
# migration-rehearsal.sh <backup set> <new work folder> <4.0 binary>: 4.0 G2's rehearsal of the production upgrade and its
# rollback, on copies only. It reads the backup set (backup-before-4.0.sh) and writes only into the work folder.
#   1 builds "Video Buddy 3.1 Test.app" from main (git archive): its own bundle ID, process name and settings, its data
#     only in the work folder (VS_DATA_DIR). Quit by its bundle ID, never by name; removed afterwards.
#   2 a synthetic v3 database made by it: made-up videos, jobs, playback and a playlist. Nothing from before Fresh Start.
#   3 for (a) production's consolidated copy and (b) the synthetic one: the 4.0 binary's --migrate-copy upgrades a copy;
#     checked: every v3 table's rows identical, the new tables empty, version 6, integrity, foreign keys, the pre-v4 backup
#   4 rollback: restore-db.sh puts the copy back to its v3 original (keeping v6 as a recovery copy); the rows are identical
#     again; 3.1 Test opens it, shows the library and runs nothing; then the undo brings v6 back
# Prints one line per check, then "rehearsal: N passed, M failed".
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
set_dir=${1:?backup set} work=${2:?new work folder} binary=${3:?4.0 binary with --migrate-copy}
[[ ! -e $work ]] || { echo "refused: $work already exists"; exit 2; }
case "$work" in "$HOME/Library/Application Support"*) echo "refused: not inside Application Support"; exit 2 ;; esac
mkdir -p "$work"; work=$(cd "$work" && pwd)
id=local.video-summarizer.rollback-test
app="$work/apps/Video Buddy 3.1 Test.app"
pass=0 fail=0
ok() { if [[ $2 == True ]]; then pass=$((pass + 1)); echo "  ✓ $1"; else fail=$((fail + 1)); echo "  ✗ $1  (got: ${3:-$2})"; fi; }
is() { [[ $1 == "$2" ]] && echo True || echo False; }

facts() {   # version|integrity|foreign key problems|table=count … (a file with a -wal through SQLite, else immutable)
  local f=$1 src counts=""
  if [[ -e "$f-wal" ]]; then src=$f; else src="file:$f?immutable=1"; fi
  for t in $(sqlite3 "$src" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"); do
    counts+="$t=$(sqlite3 "$src" "SELECT count(*) FROM \"$t\"") "; done
  echo "$(sqlite3 "$src" 'PRAGMA user_version')|$(sqlite3 "$src" 'PRAGMA integrity_check' | head -1)|$(sqlite3 "$src" 'PRAGMA foreign_key_check' | wc -l | tr -d ' ')|$counts"
}
v3dump() {  # every v3 table's rows, in a fixed order
  local src=$1; [[ -e "$1-wal" ]] || src="file:$1?immutable=1"
  for t in videos jobs meta playback collections collection_items; do echo "== $t"; sqlite3 "$src" "SELECT * FROM $t ORDER BY 1, 2"; done
}

running() { pgrep -x VideoBuddy31Test > /dev/null; }
quit31() {
  osascript -e "tell application id \"$id\" to quit" > /dev/null 2>&1
  for _ in $(seq 40); do running || return 0; sleep 0.25; done
  pkill -x VideoBuddy31Test; sleep 1      # its own process name: production 3.1 is VideoSummarizer
}
state31() {  # <python expression on the state s>
  rm -f "$work/shots/state.json"; "$work/vsctl31" state
  for _ in $(seq 60); do [[ -s $work/shots/state.json ]] && break; sleep 0.1; done
  python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$work/shots/state.json" "$1" 2> /dev/null || echo "?"
}
launch31() {  # <data folder>
  mkdir -p "$work/shots" "$work/downloads"
  open -n -g -a "$app" --env VS_DATA_DIR="$1" --env VS_TEST_HOOKS=1 --env VS_SNAPSHOT_DIR="$work/shots" --args -downloadDir "$work/downloads"
  for _ in $(seq 80); do [[ $(state31 True) == True ]] && break; sleep 0.25; done
}
cleanup() {
  running && quit31
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2> /dev/null
  defaults delete "$id" 2> /dev/null
  rm -rf "$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id" "$HOME/Library/WebKit/$id" "$HOME/Library/Saved Application State/$id.savedState"
}
trap cleanup EXIT

echo "== 1 Video Buddy 3.1 Test, built from main ($(git -C "$repo" rev-parse --short main))"
pgrep -x VideoSummarizer > /dev/null && echo "  (production 3.1 is running; it isn't touched)"
mkdir -p "$work/src" "$app/Contents/MacOS" "$app/Contents/Resources/raycast"
git -C "$repo" archive main app scripts raycast | tar -x -C "$work/src"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 $(find "$work/src/app/Sources" -name '*.swift' | sort) \
  -o "$app/Contents/MacOS/VideoBuddy31Test" 2> "$work/build31.log" || { echo "3.1 build failed:"; tail "$work/build31.log"; exit 1; }
cp "$work/src/app/Info.plist" "$app/Contents/"
for kv in "CFBundleIdentifier $id" "CFBundleExecutable VideoBuddy31Test" "CFBundleName Video Buddy 3.1 Test"; do
  /usr/libexec/PlistBuddy -c "Set :${kv%% *} ${kv#* }" "$app/Contents/Info.plist"; done
cp -Rp "$work/src/scripts" "$app/Contents/Resources/scripts"; cp -p "$work/src/raycast/summarize.sh" "$app/Contents/Resources/raycast/"
swiftc "$work/src/app/tests/vsctl.swift" -o "$work/vsctl31" 2> /dev/null
ok "3.1 Test: its own identity ($id), its self-test passes" "$("$app/Contents/MacOS/VideoBuddy31Test" --selftest > "$work/selftest31.log" 2>&1 && echo True || echo False)" "$(tail -3 "$work/selftest31.log")"

echo "== 2 a synthetic v3 database (made-up data only)"
S="$work/synthetic/make"; mkdir -p "$S"
launch31 "$S"; quit31
ok "made by 3.1 Test: v3" "$(is "$(sqlite3 "$S/history.sqlite" 'PRAGMA user_version')" 3)"
ffmpeg -v error -f lavfi -i sine=duration=2 "$work/downloads/Rehearsal one.mp3"
t=1767225600
sqlite3 "$S/history.sqlite" <<SQL
INSERT INTO videos(id, key, url, platform, title, channel, duration, upload_date, favorite, first_processed, last_processed, description) VALUES
 (1, 'url:example.com/rehearsal/1', 'https://example.com/rehearsal/1', 'example', 'Rehearsal video one', 'Synthetic channel', 600, '20260101', 1, $t, $t, 'Made up for the migration rehearsal.'),
 (2, 'url:example.com/rehearsal/2', 'https://example.com/rehearsal/2', 'example', 'Rehearsal video two', 'Synthetic channel', 300, '20260102', 0, $t, $t, NULL),
 (3, 'url:example.com/rehearsal/3', 'https://example.com/rehearsal/3', 'example', 'Rehearsal video three — مثال', 'قناة تجريبية', 120, '20260103', 0, $t, $t, NULL);
INSERT INTO jobs(id, video_id, kind, status, source, started, finished, summary, summary_language, summary_format, action) VALUES
 (1, 1, 'summary', 'succeeded', 'app', $t, $t + 60, 'A made-up summary.', 'English', 'Standard', 'summarize');
INSERT INTO jobs(id, video_id, kind, status, source, started, finished, file_path, file_size, action) VALUES
 (2, 1, 'audio', 'succeeded', 'app', $t + 100, $t + 130, '$work/downloads/Rehearsal one.mp3', 33000, 'audio');
INSERT INTO jobs(id, video_id, kind, status, source, started, finished, transcript, transcript_language, action) VALUES
 (3, 2, 'transcript', 'succeeded', 'raycast', $t + 200, $t + 260, 'A made-up transcript.', 'en', 'transcribe');
INSERT INTO jobs(id, video_id, kind, status, source, started, finished, error, action) VALUES
 (4, 3, 'video', 'failed', 'app', $t + 300, $t + 310, 'A made-up failure.', 'video');
INSERT INTO playback VALUES('$work/downloads/Rehearsal one.mp3', 42, 2, $t + 400);
INSERT INTO collections VALUES(1, 'Rehearsal playlist', 'https://example.com/rehearsal/list', $t);
INSERT INTO collection_items VALUES(1, 1, 0, $t), (1, 2, 1, $t);
SQL
mkdir -p "$work/synthetic/orig"; sqlite3 "$S/history.sqlite" ".backup '$work/synthetic/orig/history.sqlite'"
ok "filled: 3 videos, 4 jobs, playback, a playlist; integrity ok" "$(is "$(facts "$work/synthetic/orig/history.sqlite")" "3|ok|0|collection_items=2 collections=1 jobs=4 meta=$(sqlite3 "$S/history.sqlite" 'SELECT count(*) FROM meta') playback=1 videos=3 ")" "$(facts "$work/synthetic/orig/history.sqlite")"

rehearse() {  # <name> <v3 original> <titles 3.1 Test should show, as a Python list>
  local name=$1 orig=$2 titles=$3 live="$work/$1/live" migrated recovery out
  echo "== 3 migration: $name"
  mkdir -p "$live"; sqlite3 "file:$orig?immutable=1" ".backup '$live/history.sqlite'"
  local before; before=$(facts "$orig")
  out=$("$binary" --migrate-copy "$live" 2>&1); echo "  $out"
  migrated=$(facts "$live/history.sqlite")
  ok "v3 → v6, integrity ok, no foreign key problems" "$([[ $migrated == "6|ok|0|"* ]] && echo True || echo False)" "$migrated"
  ok "every v3 table's rows identical" "$(is "$(v3dump "$live/history.sqlite")" "$(v3dump "$orig")")"
  ok "the new tables are there and empty" "$([[ $migrated == *"authorizations=0 "* && $migrated == *"job_options=0 "* && $migrated == *"watch_later=0 "* ]] && echo True || echo False)" "$migrated"
  local pre; pre=$(ls "$live"/backups/history-pre-v4-*.sqlite 2> /dev/null | head -1)
  ok "a pre-v4 backup, identical to the original" "$([[ -n $pre ]] && is "$(facts "$pre")|$(v3dump "$pre")" "$before|$(v3dump "$orig")" || echo False)" "${pre:-none}"
  echo "== 4 rollback: $name"
  out=$("$repo/app/tools/restore-db.sh" "$live" "$orig" 2>&1); local code=$?
  recovery=$(sed -n 's/^saved the current state: //p' <<<"$out")
  ok "restore-db.sh: back to the v3 original, v6 kept as a recovery copy" "$([[ $code == 0 && -f $recovery ]] && is "$(facts "$recovery")" "$migrated" || echo False)" "$code $(tail -2 <<<"$out")"
  ok "…the rows identical to before the migration, nothing of 4.0 left" "$(is "$(facts "$live/history.sqlite")|$(v3dump "$live/history.sqlite")" "$before|$(v3dump "$orig")")" "$(facts "$live/history.sqlite")"
  local jobs; jobs=$(sqlite3 "$live/history.sqlite" 'SELECT count(*) FROM jobs')
  launch31 "$live"
  ok "3.1 Test opens it and shows the library" "$(state31 "sorted(v['title'] for v in s['visible']) == sorted($titles)")" "$(state31 "[v['title'] for v in s['visible']]")"
  sleep 3
  ok "…and runs nothing" "$(state31 "s['queue'] == [] and not s['isRunning']")" "$(state31 "s['queue'], s['isRunning']")"
  quit31
  ok "…no new job, integrity ok" "$(is "$(sqlite3 "$live/history.sqlite" 'SELECT count(*) FROM jobs')|$(sqlite3 "$live/history.sqlite" 'PRAGMA integrity_check')" "$jobs|ok")"
  out=$("$repo/app/tools/restore-db.sh" "$live" "$recovery" 2>&1); code=$?
  ok "undo: the v6 state back" "$([[ $code == 0 ]] && is "$(facts "$live/history.sqlite")" "$migrated" || echo False)" "$code $(tail -2 <<<"$out")"
}
rehearse production "$set_dir/production/history.sqlite" "[]"
rehearse synthetic "$work/synthetic/orig/history.sqlite" "['Rehearsal video one', 'Rehearsal video two', 'Rehearsal video three — مثال']"

echo "== 5 the Preview carry-over, on the upgraded production copy"
C="$work/production/live" carry="$repo/app/tools/carry-over.sh" pv="$set_dir/preview"
before=$(facts "$C/history.sqlite")
VB_REHEARSE_PAUSE=30 "$carry" "$pv" "$C" > "$work/carry-killed.log" 2>&1 & cpid=$!
sq=; for _ in $(seq 100); do sq=$(pgrep -P $cpid -x sqlite3) && [[ -n $(pgrep -P "$sq") ]] && break; sleep 0.1; done
kill -9 $sq $cpid 2> /dev/null; wait $cpid 2> /dev/null; sleep 1     # only the rehearsal's own processes
ok "force-quit before COMMIT (killed mid-transaction): nothing changed, integrity ok" "$([[ -n $sq ]] && is "$(facts "$C/history.sqlite")" "$before" || echo False)" "${sq:-no sqlite3 seen} $(facts "$C/history.sqlite")"
out=$("$carry" "$pv" "$C" 2>&1); echo "$out" | sed 's/^/    /'
after=$(facts "$C/history.sqlite")
keys=$(sqlite3 "$C/history.sqlite" "SELECT group_concat(video_key, ' ') FROM (SELECT video_key FROM watch_later ORDER BY 1)")
ok "exactly the two Watch Later videos, nothing else, no declaration" "$([[ ${after/watch_later=2 /watch_later=0 } == "$before" && $keys == "youtube:DYPJcnnhvQE youtube:GV1MWu7crNk" ]] && echo True || echo False)" "$after $keys"
ok "…their thumbnails, byte for byte" "$(cmp -s "$C/watch-later/GV1MWu7crNk.jpg" "$pv/watch-later/GV1MWu7crNk.jpg" && cmp -s "$C/watch-later/DYPJcnnhvQE.jpg" "$pv/watch-later/DYPJcnnhvQE.jpg" && echo True || echo False)"
tabs_ok=$(python3 -c 'import json, sys; a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2])); print(all(set(t) == {"id", "url", "title"} for t in a["tabs"]) and [(t["url"], t["title"]) for t in a["tabs"]] == [(t["url"], t["title"]) for t in b["tabs"]] and a["active"] == b["active"])' "$C/browser/tabs.json" "$pv/browser/tabs.json")
ok "…the tabs: address and title only, no WebKit history, no website data" "$([[ $tabs_ok == True && ! -e $C/browser/website-data-id ]] && echo True || echo False)"
snap="$(facts "$C/history.sqlite")|$(shasum "$C/browser/tabs.json" "$C"/watch-later/*)"
"$carry" "$pv" "$C" > /dev/null 2>&1
ok "a second run changes nothing" "$(is "$(facts "$C/history.sqlite")|$(shasum "$C/browser/tabs.json" "$C"/watch-later/*)" "$snap")"
D="$work/production/with-declaration"; mkdir -p "$D"; sqlite3 "$C/history.sqlite" ".backup '$D/history.sqlite'"; sqlite3 "$D/history.sqlite" "DELETE FROM watch_later"
"$carry" "$pv" "$D" --declaration > /dev/null 2>&1
ok "--declaration: your gx7F8fg49QQ declaration only, not the Preview's sample one" "$(is "$(sqlite3 "$D/history.sqlite" "SELECT group_concat(video_key || ' ' || basis || ' ' || reference) FROM authorizations")" "youtube:gx7F8fg49QQ written_permission mine")"
ok "the Preview backup is unchanged" "$(cd "$set_dir" && shasum -a 256 -c MANIFEST.txt > /dev/null 2>&1 && echo True || echo False)"

echo "rehearsal: $pass passed, $fail failed"
((fail == 0))
