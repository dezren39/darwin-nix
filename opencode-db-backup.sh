#!/usr/bin/env bash
# Back up the OpenCode database with a completion proof (#1758).
#
# `just opencode-db-backup` is the only backup of the live OpenCode
# database, and the safety net the prune/vacuum recipes run behind.
# The pre-#1758 recipe proved neither of the two things its success
# line claimed:
#
# 1. That both clones landed. The copies ran as sqlite3 `.shell`
#    commands, and sqlite3 exits 0 even when a `.shell` command fails,
#    so a failed WAL clone still reached `echo "backup: ..."`. This
#    script has each `.shell` clone touch a sentinel file on success
#    and refuses to publish unless every sentinel is present.
# 2. That the copy's content matches the live database. The old
#    opencode-db-check only counted the copy's own rows, so a copy
#    missing its WAL passed. This script records the live
#    session/migration counts inside the same BEGIN IMMEDIATE lock
#    the clones are taken under, and compares the staged copy against
#    them before publishing; any difference fails the run.
#
# The copy is staged under backup/.<ts>-partial — a name
# opencode-db-backup-prune.sh does not count as a backup — and is
# renamed to backup/<ts> only after both proofs pass, so a failed run
# is invisible to retention by construction and leaves no
# timestamp-named directory behind (the staging dir is removed on
# failure).
#
# Test seams (used by opencode-db-backup.test.sh):
#   OPENCODE_DB_PATH     database to back up
#                        (default ~/.local/share/opencode/opencode.db)
#   OPENCODE_DB_SQLITE3  sqlite3 binary (default /usr/bin/sqlite3)
#   OPENCODE_DB_CLONE_CP clone command (default "/bin/cp -c", the
#                        macOS clonefile copy the recipe has always
#                        used; word-split on purpose)
#
# Run: ./opencode-db-backup.sh
# It is run by the flake check `opencode-db-backup-tests`
# (via opencode-db-backup.test.sh) and by the just recipe
# `opencode-db-backup`.
set -euo pipefail

die() { echo "opencode-db-backup: $1" >&2; exit 1; }

db="${OPENCODE_DB_PATH:-$HOME/.local/share/opencode/opencode.db}"
sqlite3_bin="${OPENCODE_DB_SQLITE3:-/usr/bin/sqlite3}"
clone_cp="${OPENCODE_DB_CLONE_CP:-/bin/cp -c}"
root="$(dirname "$db")/backup"
ts="$(date +%Y%m%dT%H%M%S)"
staging="$root/.${ts}-partial"
dest="$root/$ts"

[ -f "$db" ] || die "no database at $db"
[ ! -e "$dest" ] || die "backup directory already exists: $dest"
mkdir -p "$root" "$staging"

published=0
cleanup() {
  if [ "$published" -ne 1 ]; then rm -rf "$staging"; fi
}
trap cleanup EXIT

# BEGIN IMMEDIATE takes SQLite's write lock: no commit lands and the
# WAL cannot be reset while it is held. A checkpoint can still copy
# WAL frames into the main file between the two clones, which is
# harmless: the WAL clone still holds every frame and replays them on
# open. cp -c is clonefile(2): atomic, and no extra disk until the
# files diverge. The expected counts are written by the locked
# session itself, so they describe exactly the database the clones
# are taken from.
"$sqlite3_bin" "$db" <<SQL
.timeout 120000
BEGIN IMMEDIATE;
.output "$staging/.expected"
select 'sessions', count(*) from session;
select 'migrations', count(*), max(id) from migration;
.output stdout
.shell $clone_cp "$db" "$staging/opencode.db" && touch "$staging/.db-cloned"
.shell if [ -f "$db-wal" ]; then $clone_cp "$db-wal" "$staging/opencode.db-wal" && touch "$staging/.wal-cloned"; else touch "$staging/.wal-absent"; fi
ROLLBACK;
SQL

[ -f "$staging/.db-cloned" ] || die "clone of opencode.db failed; backup not published"
if [ -f "$staging/.wal-cloned" ] && [ -f "$staging/.wal-absent" ]; then
  die "clone sentinels inconsistent; backup not published"
fi
if [ ! -f "$staging/.wal-cloned" ] && [ ! -f "$staging/.wal-absent" ]; then
  die "clone of opencode.db-wal failed; backup not published"
fi

actual="$("$sqlite3_bin" "file:$staging/opencode.db?mode=ro" \
  "select 'sessions', count(*) from session;" \
  "select 'migrations', count(*), max(id) from migration;")"
expected="$(cat "$staging/.expected")"
[ "$actual" = "$expected" ] \
  || die "backup content differs from the live database (expected [$expected], got [$actual]); backup not published"

rm -f "$staging/.expected" "$staging/.db-cloned" "$staging/.wal-cloned" "$staging/.wal-absent"
chmod 600 "$staging"/opencode.db*
mv "$staging" "$dest"
published=1
echo "backup: $dest"
"$sqlite3_bin" "file:$dest/opencode.db?mode=ro" \
  "select 'sessions', count(*) from session;" \
  "select 'migrations', count(*), max(id) from migration;"
