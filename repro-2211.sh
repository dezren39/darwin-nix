#!/usr/bin/env bash
# Micro-repro for darwin-nix#2211: replicate opencode-db-backup.test.sh's
# make_db fixture exactly, then read back the committed counts after the
# holder is killed -9. POLL=bytes (default) uses the current fixture's
# raw-byte grep poll; POLL=committed polls a real sqlite read instead.
# Each iteration prints "iter N: sessions=<s> migrations=<m>|<max>".
set -u
SQLITE3="$(command -v sqlite3)"
POLL="${POLL:-bytes}"
ITERS="${ITERS:-60}"
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
    "INSERT INTO migration VALUES('m2');" >&9
  if [ "$POLL" = committed ]; then
    for i in $(seq 1 50); do
      seen="$("$SQLITE3" "$D/opencode.db" "select count(*) from session; select count(*) || '|' || max(id) from migration;" 2>/dev/null)"
      [ "$seen" = "3
2|m2" ] && break
      sleep 0.1
    done
  else
    for i in $(seq 1 50); do
      grep -a -q 'm2' "$D/opencode.db-wal" 2>/dev/null && break
      sleep 0.1
    done
  fi
  kill -9 "$holder" 2>/dev/null
  exec 9>&-
  wait "$holder" 2>/dev/null
  counts="$("$SQLITE3" "file:$D/opencode.db?mode=ro" "select 'sessions', count(*) from session; select 'migrations', count(*) || '|' || max(id) from migration;" 2>/dev/null | tr '\n' ' ')"
  echo "iter $n: $counts"
  case "$counts" in
    *"sessions|3 migrations|2|m2"*) ;;
    *) bad=$((bad + 1)) ;;
  esac
  rm -rf "$D"
done
echo "REPRO_RESULT poll=$POLL iters=$ITERS bad=$bad"
