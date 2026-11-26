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
# - a final re-read that fails (#2032): the run exits non-zero, prints
#   no success line, and publishes no timestamp-named directory;
# - a clone cp that silently drops the WAL copy: the content check
#   (live counts recorded under the write lock vs the staged copy)
#   fails the run and nothing is published;
# - same-second/overlapping runs (#2065): a run whose start second's
#   backup name is already taken retries under a free timestamp, and
#   two concurrent runs stage privately and both publish.
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
  # Poll a real read, not the WAL bytes (#2211): a byte grep can see
  # m2's data frame before the transaction's commit frame lands, and
  # the kill below then discards m2 on recovery — the fixture would
  # promise rows the database never committed, and the backup (which
  # verifies against the live committed counts) publishes a correct
  # copy that fails the content assertions. A sqlite read only counts
  # committed frames, so once it reports the full fixture the kill
  # cannot uncommit anything.
  local i seen
  for i in $(seq 1 50); do
    seen="$("$SQLITE3" "$dir/opencode.db" \
      "select count(*) from session; select count(*) || '|' || max(id) from migration;" 2>/dev/null)"
    [ "$seen" = "3
2|m2" ] && break
    sleep 0.1
  done
  kill -9 "$holder" 2>/dev/null
  exec 9>&-
  wait "$holder" 2>/dev/null
  rm -f "$dir/.holder-in"
  [ -f "$dir/opencode.db-wal" ] || fail "fixture: no WAL left behind in $dir"
  grep -a -q 'm2' "$dir/opencode.db-wal" 2>/dev/null || fail "fixture: WAL in $dir lacks the un-checkpointed rows"
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

# --- argument contract (#2063) ----------------------------------------
# The parser runs before any staging or sqlite work: a scratch DB path
# is used so that falling through to backup logic would fail loudly
# instead of passing silently.
before=$failures
D="$WORK/argv"
out="$(OPENCODE_DB_PATH="$D/opencode.db" bash "$BACKUP" --help 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "--help exited $rc: $out"
printf '%s' "$out" | grep -q "usage: opencode-db-backup.sh" || fail "--help printed no usage: $out"
[ ! -e "$D" ] || fail "--help created state under the backup root"
[ "$failures" -eq "$before" ] && ok "--help prints usage, exits 0, touches nothing"
before=$failures
out="$(OPENCODE_DB_PATH="$D/opencode.db" bash "$BACKUP" extra-arg 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "extra arg exited $rc, expected 2: $out"
printf '%s' "$out" | grep -q "unknown argument: extra-arg" || fail "extra arg not named: $out"
printf '%s' "$out" | grep -q "usage: opencode-db-backup.sh" || fail "extra arg printed no usage: $out"
printf '%s' "$out" | grep -q "no database" && fail "extra arg fell through to backup logic: $out"
[ ! -e "$D" ] || fail "extra arg created state under the backup root"
[ "$failures" -eq "$before" ] && ok "extra argument is rejected by name, exits 2, touches nothing"
before=$failures
out="$(OPENCODE_DB_PATH="$D/opencode.db" bash "$BACKUP" --help extra 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "--help extra exited $rc, expected 2: $out"
printf '%s' "$out" | grep -q "unexpected argument: extra" || fail "--help extra not named: $out"
[ ! -e "$D" ] || fail "--help extra created state under the backup root"
[ "$failures" -eq "$before" ] && ok "--help with a trailing argument is rejected by name, exits 2"

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

# --- final re-read fails (#2032) ---------------------------------------
# Stub sqlite3 that delegates to the real binary except for the second
# read of the staged copy (file:.../.partial.*/opencode.db?mode=ro): the first such
# read is the content check, the second is the final re-read. Failing
# exactly the final re-read must publish nothing and print no success
# line, so exit status and output cannot disagree.
{
  printf '#!%s\n' "$BASH_BIN"
  echo 'n=0'
  echo 'if [ -f "$OPENCODE_DB_TEST_COUNT" ]; then n="$(cat "$OPENCODE_DB_TEST_COUNT")"; fi'
  echo 'for arg in "$@"; do'
  echo '  case "$arg" in'
  echo '    file:*/.partial.*/opencode.db\?mode=ro)'
  echo '      n=$((n + 1))'
  echo '      echo "$n" > "$OPENCODE_DB_TEST_COUNT"'
  echo '      if [ "$n" -eq 2 ]; then echo "stub sqlite3: forced final re-read failure" >&2; exit 9; fi'
  echo '      ;;'
  echo '  esac'
  echo 'done'
  echo 'exec "$OPENCODE_DB_TEST_REAL_SQLITE3" "$@"'
} >"$WORK/sqlite3-fail-final-read"
chmod +x "$WORK/sqlite3-fail-final-read"
before=$failures
D="$WORK/finalread"
make_db "$D"
out="$(OPENCODE_DB_PATH="$D/opencode.db" \
  OPENCODE_DB_SQLITE3="$WORK/sqlite3-fail-final-read" \
  OPENCODE_DB_TEST_COUNT="$WORK/final-read-count" \
  OPENCODE_DB_TEST_REAL_SQLITE3="$SQLITE3" \
  OPENCODE_DB_CLONE_CP="$WORK/cp-ok" \
  bash "$BACKUP" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "failing final re-read exited 0: $out"
[ "$rc" -eq 9 ] || fail "final re-read did not return the injected status 9: $rc: $out"
[ "$(cat "$WORK/final-read-count")" -eq 2 ] || fail "stub did not fail precisely the second staged read: $out"
printf '%s' "$out" | grep -q 'stub sqlite3: forced final re-read failure' || fail "final re-read failure seam was not reached: $out"
printf '%s' "$out" | grep -q '^backup:' && fail "failing final re-read still printed the success line: $out"
[ "$(ts_dirs "$D/backup")" -eq 0 ] || fail "failing final re-read left a timestamp dir behind"
[ "$(partial_dirs "$D/backup")" -eq 0 ] || fail "failing final re-read left a staging dir behind"
[ "$failures" -eq "$before" ] && ok "a failing final re-read exits non-zero, publishes nothing, and prints no success line"

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

# --- same-second destination already taken (#2065) ---------------------
# Pre-claim the current second's backup name, then run a backup: it
# must not die with "already exists" \u2014 it retries under a free
# timestamp and publishes exactly one more verified backup.
before=$failures
D="$WORK/samesec"
make_db "$D"
mkdir -p "$D/backup/$(date +%Y%m%dT%H%M%S)"
out="$(run_backup "$D" "$WORK/cp-ok")"
rc=$?
[ "$rc" -eq 0 ] || fail "same-second run exited $rc: $out"
printf '%s' "$out" | grep -q "^backup: $D/backup/" || fail "same-second run printed no success line: $out"
[ "$(ts_dirs "$D/backup")" -eq 2 ] || fail "same-second run left $(ts_dirs "$D/backup") timestamp dirs, expected 2 (pre-claimed + published)"
[ "$(partial_dirs "$D/backup")" -eq 0 ] || fail "same-second run left a staging dir behind"
pub="$(printf '%s' "$out" | sed -n 's/^backup: //p' | head -1)"
counts="$("$SQLITE3" "file:$pub/opencode.db?mode=ro" "select 'sessions', count(*) from session;" "select 'migrations', count(*), max(id) from migration;")"
[ "$counts" = "sessions|3
migrations|2|m2" ] || fail "same-second published backup content wrong: $counts"
[ "$failures" -eq "$before" ] && ok "a run whose second is already taken retries and publishes under a free timestamp"

# --- concurrent runs (#2065) --------------------------------------------
# Two backups launched together share a start second: each must stage
# privately, publish its own timestamp dir, and exit 0 \u2014 neither
# run's EXIT trap may delete the other's staging.
before=$failures
D="$WORK/concurrent"
make_db "$D"
run_backup "$D" "$WORK/cp-ok" >"$WORK/conc-a.out" 2>&1 &
pid_a=$!
run_backup "$D" "$WORK/cp-ok" >"$WORK/conc-b.out" 2>&1 &
pid_b=$!
rc_a=0; wait "$pid_a" || rc_a=$?
rc_b=0; wait "$pid_b" || rc_b=$?
[ "$rc_a" -eq 0 ] || fail "concurrent run A exited $rc_a: $(cat "$WORK/conc-a.out")"
[ "$rc_b" -eq 0 ] || fail "concurrent run B exited $rc_b: $(cat "$WORK/conc-b.out")"
grep -q '^backup: ' "$WORK/conc-a.out" || fail "concurrent run A printed no success line: $(cat "$WORK/conc-a.out")"
grep -q '^backup: ' "$WORK/conc-b.out" || fail "concurrent run B printed no success line: $(cat "$WORK/conc-b.out")"
[ "$(ts_dirs "$D/backup")" -eq 2 ] || fail "concurrent runs published $(ts_dirs "$D/backup") timestamp dirs, expected 2"
[ "$(partial_dirs "$D/backup")" -eq 0 ] || fail "concurrent runs left a staging dir behind"
[ "$failures" -eq "$before" ] && ok "two concurrent backups stage privately and both publish"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all opencode-db-backup tests passed"
