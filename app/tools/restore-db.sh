#!/bin/bash
# restore-db.sh <data folder> <backup file>: puts a Video Buddy history database back to one of its backups, safely with
# SQLite's write-ahead log. Only when you ask for it: it's never run on your Preview or production otherwise.
#   1. refuses while any process has history.sqlite, -wal or -shm open (quit Video Buddy first)
#   2. saves the current state, its log included, as backups/history-before-restore-<time>.sqlite, and checks that copy
#   3. restores through SQLite itself (.restore, then a checkpoint): never by copying files over the live database, so
#      restored pages are never mixed with an old -wal
#   4. checks integrity, foreign keys, the version and every table's row count against the backup
# The report names the recovery copy: the same script can put it back.
set -euo pipefail
dir=${1:-} backup=${2:-}
db="$dir/history.sqlite"
[[ -f $db && -f $backup ]] || { echo "usage: restore-db.sh <data folder> <backup file>"; exit 2; }

open_by=$(lsof -- "$db" "$db-wal" "$db-shm" 2>/dev/null | awk 'NR > 1 { print $1 " (pid " $2 ")" }' | sort -u || true)
if [[ -n $open_by ]]; then
  echo "refused: the database is open in:"; echo "$open_by" | sed 's/^/  /'; echo "quit it first; nothing was changed."; exit 3
fi

# "version|integrity|foreign keys|table=count …" of a database file. A file with a -wal beside it is read through SQLite
# (so its log counts); one without (a backup nothing has open) is read as immutable, which is exact for it, and works
# where a read-only open can't (a backup made by SQLite keeps the log mode, and read-only can't create its -shm).
facts() {
  local f=$1 src tables counts=""
  if [[ -e "$f-wal" ]]; then src=$f; else src="file:$f?immutable=1"; fi
  tables=$(sqlite3 "$src" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
  for t in $tables; do counts+="$t=$(sqlite3 "$src" "SELECT count(*) FROM \"$t\"") "; done
  echo "$(sqlite3 "$src" 'PRAGMA user_version')|$(sqlite3 "$src" 'PRAGMA integrity_check' | head -1)|$(sqlite3 "$src" 'PRAGMA foreign_key_check' | wc -l | tr -d ' ')|$counts"
}

mkdir -p "$dir/backups"
recovery="$dir/backups/history-before-restore-$(date +%Y%m%d-%H%M%S).sqlite"
[[ -e $recovery ]] && { echo "refused: $recovery already exists"; exit 4; }
# SQLite's backup reads the main file and its log together: changes not yet checkpointed are kept
sqlite3 "$db" ".backup '$recovery'"
now=$(facts "$db") saved=$(facts "$recovery")
IFS='|' read -r _ integrity fk _ <<<"$saved"
if [[ $integrity != ok || $fk != 0 || ${now#*|} != "${saved#*|}" ]]; then
  echo "stopped: the recovery copy didn't check out ($saved); the database was not changed."; exit 5
fi
echo "saved the current state: $recovery"
echo "  $saved"

# 4.0 G2: everything from a private copy (its -wal too, if it has one): SQLite opens a source read-write, which would
# leave a -wal and -shm beside the backup (a backup set would no longer verify). The backup itself is only copied.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/vb-restore.XXXXXX")
for s in "" -wal; do [[ -e $backup$s ]] && cp -p "$backup$s" "$scratch/backup.sqlite$s"; done
want=$(facts "$scratch/backup.sqlite")
sqlite3 "$db" ".restore '$scratch/backup.sqlite'"
rm -rf "$scratch"
sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null
got=$(facts "$db")
IFS='|' read -r version integrity fk counts <<<"$got"
echo "restored from: $backup"
echo "  $got"
if [[ $integrity != ok || $fk != 0 || $got != "$want" ]]; then
  echo "WARNING: the restored database doesn't match the backup (wanted $want)."
  echo "Put the previous state back with: $0 '$dir' '$recovery'"
  exit 6
fi
echo "ok: version $version, integrity ok, no broken foreign keys, every table's count matches the backup."
echo "to undo this restore: $0 '$dir' '$recovery'"
