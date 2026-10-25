#!/bin/bash
# carry-over.sh <Preview backup folder> <4.0 data folder> [--declaration]: 4.0 Phase 5's selective carry-over from the
# Preview into Video Buddy 4.0's data (at G3, production's after its upgrade; rehearsed on copies). Exactly:
#   Watch Later GV1MWu7crNk and DYPJcnnhvQE, with their thumbnails (watch-later/<id>.jpg)
#   the tabs, address and title only: no WebKit history and no website data, so YouTube is signed in afresh
#   with --declaration only: your gx7F8fg49QQ authorization declaration (your decision at G3)
# Nothing else: no fixture video, job, file or declaration. The Preview backup (backup-before-4.0.sh's preview/) is only
# read. The database part is one transaction, all or nothing; files are written beside their place and renamed in, never
# over an existing file; anything already there is kept, so a re-run finishes an interrupted run and changes nothing else.
# Refused while anything has the 4.0 database open, or if it isn't at version 6.
set -euo pipefail
src=${1:-} dst=${2:-} declaration=${3:-}
wl=(GV1MWu7crNk DYPJcnnhvQE) decl=gx7F8fg49QQ
[[ -f $src/history.sqlite && -f $dst/history.sqlite ]] || { sed -n 2,11p "$0"; exit 2; }
[[ -z $declaration || $declaration == --declaration ]] || { echo "unknown option: $declaration"; exit 2; }
db="$dst/history.sqlite" from="file:$src/history.sqlite?immutable=1"
open_by=$(lsof -- "$db" "$db-wal" "$db-shm" 2> /dev/null | awk 'NR > 1 { print $1 " (pid " $2 ")" }' | sort -u || true)
[[ -z $open_by ]] || { echo "refused: the database is open in: $open_by. Quit it first; nothing was changed."; exit 3; }
[[ $(sqlite3 "$db" 'PRAGMA user_version') == 6 ]] || { echo "refused: $db isn't at version 6 (upgrade it with Video Buddy 4.0 first)"; exit 3; }
keys=$(printf "'youtube:%s'," "${wl[@]}"); keys=${keys%,}
[[ $(sqlite3 "$from" "SELECT count(*) FROM watch_later WHERE video_key IN ($keys)") == "${#wl[@]}" ]] \
  || { echo "refused: the Preview backup doesn't have both Watch Later videos (${wl[*]})"; exit 3; }
counts() { sqlite3 "$db" "SELECT (SELECT count(*) FROM videos) || ' videos, ' || (SELECT count(*) FROM jobs) || ' jobs, ' ||
  (SELECT count(*) FROM watch_later) || ' Watch Later, ' || (SELECT count(*) FROM authorizations) || ' declarations'"; }
echo "before: $(counts)"

# 1 the database, in one transaction (a pause before COMMIT only for the rehearsal's force-quit test, never on live data)
pause=; [[ -n ${VB_REHEARSE_PAUSE:-} && $dst != "$HOME/Library/Application Support"* ]] && pause=".shell sleep $VB_REHEARSE_PAUSE"
sqlite3 "$db" <<SQL
.bail on
PRAGMA foreign_keys=ON;
ATTACH '$from' AS p;
BEGIN IMMEDIATE;
INSERT OR IGNORE INTO watch_later(video_key, url, title, channel, duration, thumbnail_url, added)
  SELECT video_key, url, title, channel, duration, thumbnail_url, added FROM p.watch_later WHERE video_key IN ($keys);
$([[ -n $declaration ]] && echo "INSERT OR IGNORE INTO authorizations(video_key, basis, reference, recorded)
  SELECT video_key, basis, reference, recorded FROM p.authorizations WHERE video_key = 'youtube:$decl';")
$pause
COMMIT;
SQL
echo "after:  $(counts)"

# 2 the thumbnails, never over a file that's there
mkdir -p "$dst/watch-later"
for id in "${wl[@]}"; do
  f="$dst/watch-later/$id.jpg"
  if [[ -e $f ]]; then echo "kept: $f"
  elif [[ -f $src/watch-later/$id.jpg ]]; then cp -p "$src/watch-later/$id.jpg" "$f.carry" && mv -n "$f.carry" "$f" && echo "thumbnail: $id"
  else echo "no thumbnail for $id in the backup (Video Buddy fetches it again)"; fi
done

# 3 the tabs, address and title only, unless 4.0 already has tabs
tabs="$dst/browser/tabs.json"
if [[ -e $tabs ]]; then echo "kept: $tabs (4.0 already has tabs)"
elif [[ -f $src/browser/tabs.json ]]; then
  mkdir -p "$dst/browser"
  python3 -I - "$src/browser/tabs.json" "$tabs.carry" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s.get("version") == 1
tabs = [{"id": t["id"], "url": t["url"], "title": t["title"]} for t in s["tabs"]]
json.dump({"version": 1, "active": s.get("active"), "tabs": tabs}, open(sys.argv[2], "w"), indent=1)
print("tabs: " + ", ".join(t["url"] for t in tabs))
PY
  mv -n "$tabs.carry" "$tabs"
fi
echo "integrity $(sqlite3 "$db" 'PRAGMA integrity_check'), foreign key problems $(sqlite3 "$db" 'PRAGMA foreign_key_check' | wc -l | tr -d ' ')"
