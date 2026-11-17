#!/usr/bin/env bash
# Fixture test for opencode-db-backup.sh (#1758 completion proof).
#
# Builds a WAL-mode fixture database whose newest rows exist only in
# the WAL (a holder connection is killed -9 mid-flight, the shape the
# issue's evidence used), then pins:
# - happy path: exactly one timestamp-named backup is published, it
#   carries the WAL-only rows, and no staging or sentinel files leak;
# - a clone cp that fails: the run exits non-zero, prints no success
#   line, and leaves no timestamp-named (or staging) directory, so
#   opencode-db-backup-prune.sh sees nothing to keep or delete;
# - a clone cp that silently drops the WAL copy: the content check
#   (live counts recorded under the write lock vs the staged copy)
#   fails the run and nothing is published.
#
# Run: ./opencode-db-backup.test.sh
# It is run by the flake check `opencode-db-backup-tests`.
set -u

cd "$(dirname "$0")" || exit

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $1"; }

WORK="$(mktemp -d)"
cleanup() {
  chmod -R u+rwx "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

SQLITE3="$(command -v sqlite3)"
BACKUP=./opencode-db-backup.sh
PRUNE=./opencode-db-backup-prune.sh

# $1 = dir that will hold opencode.db. After this returns, the main
# file holds session s1 / migration m1 and the WAL holds s2, s3, m2.
# The WAL-only rows are produced by a holder connection (FIFO stdin,
# so it stays open without executing anything else) that is killed
# -9 mid-flight — the shape the issue's evidence used.
make_db() {
  local dir="$1"
  mkdir -p "$dir"
  "$SQLITE3" "$dir/opencode.db" \
    "PRAGMA journal_mode=WAL; CREATE TABLE session(id TEXT PRIMARY KEY); CREATE TABLE migration(id TEXT PRIMARY KEY); INSERT INTO session VALUES('s1'); INSERT INTO migration VALUES('m1');" \
    >/dev/null || fail "fixture: could not create $dir/opencode.db"
  mkfifo "$dir/.holder-in"
  "$SQLITE3" "$dir/opencode.db" <"$dir/.holder-in" >/dev/null 2>&1 &
  local holder=$!
  exec 9>"$dir/.holder-in"
  printf '%s\n' \
    "PRAGMA wal_autocheckpoint=0;" \
    "INSERT INTO session VALUES('s2');" \
    "INSERT INTO session VALUES('s3');" \
    "INSERT INTO migration VALUES('m2');" >&9
  local i
  for i in $(seq 1 50); do
    grep -a -q 's3' "$dir/opencode.db-wal" 2>/dev/null && break
    sleep 0.1
  done
  kill -9 "$holder" 2>/dev/null
  exec 9>&-
  wait "$holder" 2>/dev/null
  rm -f "$dir/.holder-in"
  [ -f "$dir/opencode.db-wal" ] || fail "fixture: no WAL left behind in $dir"
  grep -a -q 's3' "$dir/opencode.db-wal" 2>/dev/null || fail "fixture: WAL in $dir lacks the un-checkpointed rows"
}

# Stub clone commands. The backup script invokes the clone command as
# `<cmd> <src> <dst>`; $1 is the source path. The shebang names the
# running bash by absolute path: the flake-check sandbox has no
# /usr/bin/env for the sqlite3 `.shell` to resolve.
BASH_BIN="$(command -v bash)"
{
  printf '#!%s\n' "$BASH_BIN"
  echo 'exec cp "$@"'
} >"$WORK/cp-ok"
{
  printf '#!%s\n' "$BASH_BIN"
  echo 'echo "stub cp: forced failure" >&2'
  echo 'exit 1'
} >"$WORK/cp-fail"
{
  printf '#!%s\n' "$BASH_BIN"
  echo '# Lies about the WAL copy: reports success, copies nothing.'
  echo 'case "$1" in *-wal) exit 0 ;; esac'
  echo 'exec cp "$@"'
} >"$WORK/cp-drop-wal"
chmod +x "$WORK/cp-ok" "$WORK/cp-fail" "$WORK/cp-drop-wal"

run_backup() {
  # $1 = fixture dir, $2 = stub cp path
  OPENCODE_DB_PATH="$1/opencode.db" \
    OPENCODE_DB_SQLITE3="$SQLITE3" \
    OPENCODE_DB_CLONE_CP="$2" \
    bash "$BACKUP" 2>&1
}

ts_dirs() { ls "$1" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}$' | wc -l | tr -d ' '; }
partial_dirs() { ls -a "$1" 2>/dev/null | grep -c 'partial$' | tr -d ' '; }

# --- happy path ------------------------------------------------------
before=$failures
D="$WORK/happy"
make_db "$D"
out="$(run_backup "$D" "$WORK/cp-ok")"
rc=$?
[ "$rc" -eq 0 ] || fail "happy path exited $rc: $out"
printf '%s' "$out" | grep -q "^backup: $D/backup/" || fail "happy path printed no success line: $out"
[ "$(ts_dirs "$D/backup")" -eq 1 ] || fail "happy path published $(ts_dirs "$D/backup") timestamp dirs, expected 1"
[ "$(partial_dirs "$D/backup")" -eq 0 ] || fail "happy path left a staging dir behind"
pub="$(ls -d "$D"/backup/[0-9]* 2>/dev/null | head -1)"
[ -f "$pub/opencode.db" ] || fail "published backup has no opencode.db"
[ -f "$pub/opencode.db-wal" ] || fail "published backup has no opencode.db-wal"
[ -e "$pub/.expected" ] || [ -e "$pub/.db-cloned" ] && fail "published backup leaked sentinel/expected files"
counts="$("$SQLITE3" "file:$pub/opencode.db?mode=ro" "select 'sessions', count(*) from session;" "select 'migrations', count(*), max(id) from migration;")"
[ "$counts" = "sessions|3
migrations|2|m2" ] || fail "published backup content wrong: $counts"
[ "$failures" -eq "$before" ] && ok "happy path publishes one verified backup carrying the WAL-only rows"

# --- failing clone cp --------------------------------------------------
before=$failures
D="$WORK/failing"
make_db "$D"
out="$(run_backup "$D" "$WORK/cp-fail")"
rc=$?
[ "$rc" -ne 0 ] || fail "failing cp exited 0: $out"
printf '%s' "$out" | grep -q '^backup:' && fail "failing cp still printed the success line: $out"
[ "$(ts_dirs "$D/backup")" -eq 0 ] || fail "failing cp left a timestamp dir behind"
[ "$(partial_dirs "$D/backup")" -eq 0 ] || fail "failing cp left a staging dir behind"
out="$(bash "$PRUNE" --dir "$D/backup" --keep 1 2>&1)"
printf '%s' "$out" | grep -q 'would delete:' && fail "pruner sees a phantom backup after a failed run: $out"
[ "$failures" -eq "$before" ] && ok "failing clone exits non-zero and publishes nothing retention can see"

# --- WAL copy silently dropped -----------------------------------------
before=$failures
D="$WORK/dropwal"
make_db "$D"
out="$(run_backup "$D" "$WORK/cp-drop-wal")"
rc=$?
[ "$rc" -ne 0 ] || fail "WAL-dropping cp exited 0: $out"
printf '%s' "$out" | grep -q '^backup:' && fail "WAL-dropping cp still printed the success line: $out"
[ "$(ts_dirs "$D/backup")" -eq 0 ] || fail "WAL-dropping cp left a timestamp dir behind"
[ "$(partial_dirs "$D/backup")" -eq 0 ] || fail "WAL-dropping cp left a staging dir behind"
[ "$failures" -eq "$before" ] && ok "a copy missing its WAL is caught by the content check and not published"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all opencode-db-backup tests passed"
