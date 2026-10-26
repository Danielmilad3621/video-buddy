"""Rehearse a schema-v6 patch and rollback on retained copies; no app UI or network."""
from contextlib import closing
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time

backup, work, binary = map(lambda value: Path(value).resolve(), sys.argv[1:4])
repo = Path(__file__).resolve().parents[2]
support = (Path.home() / 'Library/Application Support').resolve()
assert not work.is_relative_to(support), 'Rehearsal refuses Application Support'
assert work != backup and not work.is_relative_to(backup), 'Rehearsal refuses the backup set'
passed = 0


def check(condition, label):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASSED: ' + label, flush=True)


def run(args, log):
    result = subprocess.run(args, text=True, capture_output=True)
    (work / log).write_text(result.stdout + result.stderr)
    check(result.returncode == 0, log)
    return result.stdout


def snapshot(db):
    # Only closed, consolidated copies are read through immutable SQLite.
    with closing(sqlite3.connect(db.as_uri() + '?immutable=1', uri=True)) as connection:
        check(connection.execute('PRAGMA integrity_check').fetchone()[0] == 'ok', db.parent.name + ': integrity')
        check(not connection.execute('PRAGMA foreign_key_check').fetchall(), db.parent.name + ': foreign keys')
        return connection.execute('PRAGMA user_version').fetchone()[0], '\n'.join(connection.iterdump())


run(['/bin/bash', str(repo / 'app/tools/backup-before-4.0.sh'), '--verify', str(backup)], 'verify-before.log')
source = backup / 'production/history.sqlite'
original = snapshot(source)
check(original[0] == 6, 'input is current schema v6')
live = work / 'live'
live.mkdir()
db = live / 'history.sqlite'
shutil.copy2(source, db)
run([str(binary), '--migrate-copy', str(live)], 'migrate-current.log')
check(snapshot(db) == original, 'new binary preserves every schema-v6 table and row')
run([str(binary), '--migrate-copy', str(live)], 'migrate-repeat.log')
check(snapshot(db) == original, 'a second open remains identical')

# A synthetic change proves that rollback restores data and that its recovery copy can undo the restore.
with closing(sqlite3.connect(db)) as connection:
    check(not connection.execute("SELECT 1 FROM meta WHERE key='__patch_rehearsal__'").fetchall(), 'marker is test-only')
    connection.execute("INSERT INTO meta(key,value) VALUES('__patch_rehearsal__','temporary rehearsal')")
    connection.commit()
    connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
changed = snapshot(db)
harness = 'rm() { printf "Retained: %s\\n" "$*" >&2; }; export -f rm; exec /bin/bash "$@"'
restore = str(repo / 'app/tools/restore-db.sh')
output = run(['/bin/bash', '-c', harness, 'retained-restore', restore, str(live), str(source)], 'restore.log')
recovery = next(Path(line.split(': ', 1)[1]) for line in output.splitlines() if line.startswith('saved the current state: '))
check(snapshot(db) == original, 'rollback restores every original row')
check(snapshot(recovery) == changed, 'rollback preserves the changed copy for undo')
time.sleep(1.1)  # restore-db names recovery copies to the second.
run(['/bin/bash', '-c', harness, 'retained-restore', restore, str(live), str(recovery)], 'undo-restore.log')
check(snapshot(db) == changed, 'undo restores the test change')

# Check the actual backed-up 4.0 binary with an isolated bundle identity on a fresh copy.
old_root = work / 'previous-app'
old_root.mkdir()
run(['/usr/bin/ditto', '-x', '-k', str(backup / 'apps/Video Buddy.app.zip'), str(old_root)], 'extract-old-app.log')
old_app = old_root / 'Video Buddy.app'
plist = old_app / 'Contents/Info.plist'
run(['/usr/bin/plutil', '-replace', 'CFBundleIdentifier', '-string', 'local.video-summarizer.rollback-test', str(plist)], 'isolate-old-app.log')
run(['/usr/bin/plutil', '-replace', 'VBPreview', '-bool', 'YES', str(plist)], 'isolate-old-rules.log')
run(['/usr/bin/codesign', '--force', '--sign', '-', str(old_app)], 'sign-old-test.log')
compat = work / 'previous-version-copy'
compat.mkdir()
shutil.copy2(source, compat / 'history.sqlite')
run([str(old_app / 'Contents/MacOS/VideoSummarizer'), '--migrate-copy', str(compat)], 'previous-version-open.log')
check(snapshot(compat / 'history.sqlite') == original, 'previous 4.0 binary opens the rollback copy without changing any row')
run(['/bin/bash', str(repo / 'app/tools/backup-before-4.0.sh'), '--verify', str(backup)], 'verify-after.log')
print(f'rehearsal: {passed} passed, 0 failed; all files retained in {work}')
