#!/bin/bash
# backup-before-4.0.sh <new folder> | --verify <folder>: the verified backup set taken before Video Buddy 4.0 replaces 3.1.
# It only reads your apps and data, and writes only into the new folder:
#   apps/          Video Buddy.app (3.1) and Video Buddy 4.0 Preview.app, zipped with ditto (attributes kept)
#   production/    3.1's history.sqlite with its -wal and -shm, copied together (raw/) and checked byte for byte against
#                  the originals; history.sqlite, one consolidated file made by SQLite's .backup from a scratch copy of
#                  those (the originals are never opened by SQLite); its backups/ and thumbnails/
#   preview/       the same for the Preview's database, plus its backups/, thumbnails/, browser/ (tabs) and watch-later/
#   settings/      `defaults export` of 3.1, the Preview and the RC
#   media.txt      every file in 3.1's and the Preview's download folders (size, date), and every media path the two
#                  databases name, with whether it's there. Media files themselves aren't copied.
#   MANIFEST.txt   SHA-256 of every file above. --verify checks it, and each consolidated database's integrity.
# Refused while 3.1 or the Preview runs or anything has a database open. It never quits an app: you do that.
set -euo pipefail
support="$HOME/Library/Application Support"
prod="$support/Video Summarizer" preview="$support/Video Buddy 4.0 Preview"

# "version|integrity|foreign keys|table=count …" of a database: read through SQLite with its -wal if it has one (a scratch
# copy), else as immutable (a finished backup nothing has open; never used on a live database)
facts() {
  local f=$1 src tables counts=""
  if [[ -e "$f-wal" ]]; then src=$f; else src="file:$f?immutable=1"; fi
  tables=$(sqlite3 "$src" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
  for t in $tables; do counts+="$t=$(sqlite3 "$src" "SELECT count(*) FROM \"$t\"") "; done
  echo "$(sqlite3 "$src" 'PRAGMA user_version')|$(sqlite3 "$src" 'PRAGMA integrity_check' | head -1)|$(sqlite3 "$src" 'PRAGMA foreign_key_check' | wc -l | tr -d ' ')|$counts"
}

verify() {
  local dir=$1 bad=0
  [[ -f $dir/MANIFEST.txt ]] || { echo "verify: no MANIFEST.txt in $dir"; exit 2; }
  (cd "$dir" && shasum -a 256 -c MANIFEST.txt > /dev/null 2> /dev/null) || { echo "verify: FAILED: files differ from MANIFEST.txt:"
    (cd "$dir" && shasum -a 256 -c MANIFEST.txt 2>&1 | grep -v ': OK$' | sed 's/^/  /') || true; bad=1; }
  local extra; extra=$(cd "$dir" && comm -13 <(sed 's/^[0-9a-f]*  //' MANIFEST.txt | sort) <(find . -type f ! -name MANIFEST.txt | sort))
  [[ -z $extra ]] || { echo "verify: FAILED: files not in MANIFEST.txt:"; echo "$extra" | sed 's/^/  /'; bad=1; }
  for db in "$dir"/production/history.sqlite "$dir"/preview/history.sqlite; do
    [[ -f $db ]] || continue
    local f; f=$(facts "$db"); IFS='|' read -r _ integrity fk _ <<<"$f"
    [[ $integrity == ok && $fk == 0 ]] || { echo "verify: FAILED: $db: $f"; bad=1; }
    echo "verify: ${db#"$dir"/}: v$f" | sed 's/|/, integrity /; s/|/, foreign key problems /; s/|/, /'
  done
  ((bad == 0)) && echo "verify: ok: $(wc -l < "$dir/MANIFEST.txt" | tr -d ' ') files match MANIFEST.txt, databases intact"
  return $bad
}

# <data folder> <dest>: the database (raw and consolidated) and the folders that go with it
database() {
  local src=$1 dest=$2 scratch before after copied
  local db="$src/history.sqlite"
  open_by=$(lsof -- "$db" "$db-wal" "$db-shm" 2> /dev/null | awk 'NR > 1 { print $1 " (pid " $2 ")" }' | sort -u || true)
  [[ -z $open_by ]] || { echo "stopped: $db is open in: $open_by. Quit it first; nothing more was copied."; exit 3; }
  mkdir -p "$dest/raw"
  local files=(); for s in "" -wal -shm; do [[ -e $db$s ]] && files+=("$db$s"); done
  before=$(shasum -a 256 "${files[@]}" | awk '{print $1}')
  cp -p "${files[@]}" "$dest/raw/"
  copied=$(cd "$dest/raw" && shasum -a 256 "${files[@]##*/}" | awk '{print $1}')
  after=$(shasum -a 256 "${files[@]}" | awk '{print $1}')
  [[ $before == "$copied" && $copied == "$after" ]] || { echo "stopped: $db changed while it was copied (is something using it?)"; exit 4; }
  # the consolidated copy: SQLite reads the scratch copy's main file and log together and writes one file
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/vb-backup.XXXXXX")
  cp -p "$dest/raw/"* "$scratch/"
  sqlite3 "$scratch/history.sqlite" ".backup '$dest/history.sqlite'"
  local want got; want=$(facts "$scratch/history.sqlite") got=$(facts "$dest/history.sqlite")
  # the media paths it names, for the inventory
  sqlite3 "$scratch/history.sqlite" "SELECT DISTINCT file_path FROM jobs WHERE file_path IS NOT NULL ORDER BY 1" > "$scratch/paths"
  { echo "## media paths in ${src##*/}'s database"; while IFS= read -r p; do echo "$([[ -e $p ]] && echo here || echo missing)  $p"; done < "$scratch/paths"; } >> "$out/media.txt"
  rm -rf "$scratch"
  IFS='|' read -r _ integrity fk _ <<<"$got"
  [[ $got == "$want" && $integrity == ok && $fk == 0 ]] || { echo "stopped: the consolidated copy of $db doesn't check out ($got; wanted $want)"; exit 5; }
  echo "  ${src##*/}: raw files identical to the originals; consolidated copy v$got" | sed 's/|/, integrity /; s/|/, foreign key problems /; s/|/, /'
  for d in "${@:3}"; do [[ -d $src/$d ]] && ditto "$src/$d" "$dest/$d"; done
  return 0
}

[[ ${1:-} == --verify ]] && { verify "${2:?folder}"; exit; }
out=${1:-}
[[ -n $out ]] || { sed -n 2,14p "$0"; exit 2; }
[[ ! -e $out ]] || { echo "refused: $out already exists; give a new folder"; exit 2; }
for p in VideoSummarizer VideoBuddyPreview; do
  pgrep -x "$p" > /dev/null && { echo "refused: $p is running. Quit it yourself first (this script never quits an app); nothing was copied."; exit 3; }
done
case "$out" in "$support"*) echo "refused: not inside Application Support"; exit 2 ;; esac
mkdir -p "$out/apps" "$out/settings"
out=$(cd "$out" && pwd)
echo "backup set: $out"

database "$prod" "$out/production" backups thumbnails
database "$preview" "$out/preview" backups thumbnails browser watch-later

for a in "Video Buddy" "Video Buddy 4.0 Preview"; do
  [[ -d "$HOME/Applications/$a.app" ]] && ditto -c -k --keepParent "$HOME/Applications/$a.app" "$out/apps/$a.app.zip"
done
for id in local.video-summarizer local.video-summarizer.preview local.video-summarizer.rc; do
  defaults export "$id" "$out/settings/$id.plist" 2> /dev/null || echo "  (no settings for $id)"
done
{ echo "## files in the download folders"
  for d in "$HOME/Downloads/cobalt" "$preview/Downloads"; do
    echo "# $d"; [[ -d $d ]] && find "$d" -type f ! -name .DS_Store -exec stat -f '%z  %Sm  %N' {} + | sort -k4
  done; } >> "$out/media.txt"
(cd "$out" && find . -type f ! -name MANIFEST.txt -print0 | sort -z | xargs -0 shasum -a 256) > "$out/MANIFEST.txt"
echo "  apps: $(ls "$out/apps" | tr '\n' ' ')"
verify "$out"
