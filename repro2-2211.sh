#!/usr/bin/env bash
# Widened-window repro for darwin-nix#2211. Same fixture shape as
# opencode-db-backup.test.sh's make_db, except the holder's final
# transaction is one BEGIN..COMMIT whose data (~9MB of pad rows)
# exceeds the page cache, so WAL frames spill to the file throughout
# the transaction while the commit frame lands only at the end: the
# readiness poll + kill -9 can land mid-transaction. POLL=bytes uses the current
# fixture's raw-byte grep; POLL=committed polls a real sqlite read.
# An iteration is "bad" when a post-kill read cannot see m2, i.e. the
# kill discarded a transaction the poll had already declared ready.
set -u
SQLITE3="$(command -v sqlite3)"
POLL="${POLL:-bytes}"
ITERS="${ITERS:-20}"
bad=0
for n in $(seq 1 "$ITERS"); do
  D="$(mktemp -d)"
  "$SQLITE3" "$D/opencode.db" \
    "PRAGMA journal_mode=WAL; CREATE TABLE session(id TEXT PRIMARY KEY); CREATE TABLE migration(id TEXT PRIMARY KEY); INSERT INTO session VALUES('s1'); INSERT INTO migration VALUES('m1');" \
    >/dev/null
  mkfifo "$D/.holder-in"
  "$SQLITE3" "$D/opencode.db" <"$D/.holder-in" >/dev/null 2>&1 &
  holder=$!
  exec 9>"$D/.holder-in"
  printf '%s\n' \
    "PRAGMA wal_autocheckpoint=0;" \
    "INSERT INTO session VALUES('s2');" \
    "INSERT INTO session VALUES('s3');" \
    "BEGIN;" \
    "INSERT INTO migration VALUES('m2');" \
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 600000) INSERT INTO migration SELECT 'pad' || x FROM c;" \
    "COMMIT;" >&9
  if [ "$POLL" = committed ]; then
    for i in $(seq 1 200); do
      seen="$("$SQLITE3" "$D/opencode.db" "select count(*) from migration where id='m2';" 2>/dev/null)"
      [ "$seen" = "1" ] && break
      sleep 0.05
    done
  else
    for i in $(seq 1 100); do
      grep -a -q 'm2' "$D/opencode.db-wal" 2>/dev/null && break
      sleep 0.05
    done
  fi
  kill -9 "$holder" 2>/dev/null
  exec 9>&-
  wait "$holder" 2>/dev/null
  seen="$("$SQLITE3" "file:$D/opencode.db?mode=ro" "select count(*) from migration where id='m2';" 2>/dev/null)"
  echo "iter $n: m2 visible after kill: $seen"
  [ "$seen" = "1" ] || bad=$((bad + 1))
  rm -rf "$D"
done
echo "REPRO2_RESULT poll=$POLL iters=$ITERS bad=$bad"
