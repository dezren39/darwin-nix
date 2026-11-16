#!/usr/bin/env bash
# Regression test for the argument parsers of opencode-db-vacuum.sh and
# opencode-db-prune.sh (#941, the #930 pattern; #1112 repeats/conflicts).
#
# A value-taking option must reject an empty or flag-shaped value, dying
# with a message that names the option — otherwise the next option is
# swallowed as the value and never parsed: "opencode-db-vacuum.sh --into
# --dry-run" used to run a REAL vacuum against the live database, because
# --dry-run became the --into path. The missing-value case (option last
# on the line) was already guarded by ${2:?}; this test pins both cases
# for every value-taking option in both scripts, plus controls showing
# valid values still parse.
#
# #1129: restore mode (--restore-session) silently ignored the prune-only
# options --backup/--no-backup/--protect-days/--protect-roots/--batch
# (only --archive was rejected). The restore branch now rejects each of
# them naming the option; the pins are below, after the #1112 checks.
#
# Run: ./opencode-db-args.test.sh
# It is run by the flake check `opencode-db-args-tests`.
set -u

cd "$(dirname "$0")" || exit

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared conformance probe matrix (design #1145; phase 2 / #1147 folds
# this suite into it and extends it to opencode-db-backup-prune.sh).
# shellcheck source=lib/arg-probe.sh
. "$SELF_DIR/lib/arg-probe.sh"

# Hermetic environment harness (design #1473, phase 1 / #1474): scratch
# HOME/TMPDIR/XDG under one root, removed by its EXIT trap; the scoped
# `ps` double for the apply-mode section below is shared with the vacuum
# suite rather than copied here.
# shellcheck source=lib/test-harness.sh
. "$SELF_DIR/lib/test-harness.sh"
harness_init || exit 1

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $1"; }

# check_rejected <script> <option> <flag-shaped value...>
# The invocation must exit non-zero before doing any work, with stderr
# naming the option.
check_rejected() {
  local script="$1" opt="$2"; shift 2
  local out rc
  out="$(bash "$script" "$opt" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$script $opt $*: exited 0"
  elif ! printf '%s' "$out" | grep -q -- "$opt"; then
    fail "$script $opt $*: error does not name the option: $out"
  else
    ok "$script $opt $* rejected, naming $opt"
  fi
}

VAC=./opencode-db-vacuum.sh
PRUNE=./opencode-db-prune.sh
BP=./opencode-db-backup-prune.sh

# run <script> <args...> -- sets OUT, ERR, STATUS (lib/arg-probe.sh harness)
run() {
  local script="$1"; shift
  OUT="$(bash "$script" "$@" 2>"$HOME/probe-err")"; STATUS=$?
  ERR="$(cat "$HOME/probe-err")"
}

# Flag-shaped values: the swallowed flag is the dangerous case (#930).
for opt in --db --into; do
  check_rejected "$VAC" "$opt" --dry-run
  check_rejected "$VAC" "$opt"        # no value at all
  check_rejected "$VAC" "$opt" ""     # empty value
done
for opt in --db --protect-days --backup --archive --restore-session --from --batch; do
  check_rejected "$PRUNE" "$opt" --apply
  check_rejected "$PRUNE" "$opt"      # no value at all
  check_rejected "$PRUNE" "$opt" ""   # empty value
done

# Repeated value options (#1112, the adopt #1103 pattern): the last value
# used to silently win, so a duplicated --db redirected the destructive
# operation to a different database with no error. Every value-taking
# option in both scripts must reject a repeat at parse time, naming the
# option with "may be given only once", before any work happens.
check_repeated() {
  local script="$1" opt="$2"; shift 2
  local out rc
  out="$(bash "$script" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$script $*: repeated $opt exited 0"
  elif ! printf '%s' "$out" | grep -q -- "$opt may be given only once"; then
    fail "$script $*: repeated $opt error does not name the repetition: $out"
  else
    ok "$script repeated $opt rejected at parse time"
  fi
}
check_repeated "$VAC" --db --db /tmp/a.db --db /tmp/b.db
check_repeated "$VAC" --into --into /tmp/a.out --into /tmp/b.out
check_repeated "$PRUNE" --db --db /tmp/a.db --db /tmp/b.db
check_repeated "$PRUNE" --protect-days --protect-days 1 --protect-days 2
check_repeated "$PRUNE" --backup --backup /tmp/a.bak --backup /tmp/b.bak
check_repeated "$PRUNE" --archive --archive /tmp/a.arc --archive /tmp/b.arc
check_repeated "$PRUNE" --restore-session --restore-session ses_a --restore-session ses_b
check_repeated "$PRUNE" --from --from /tmp/a.src --from /tmp/b.src
check_repeated "$PRUNE" --batch --batch 1 --batch 2

# Prune --backup + --no-backup (#1112): in either order the combination
# used to silently produce no backup at all, ignoring the explicit
# --backup. It must be rejected at parse time naming the combination.
check_backup_conflict() {
  local out rc
  out="$(bash "$PRUNE" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "prune $*: --backup + --no-backup exited 0"
  elif ! printf '%s' "$out" | grep -q -- "--backup and --no-backup may not be combined"; then
    fail "prune $*: --backup + --no-backup error does not name the combination: $out"
  else
    ok "prune $* rejected (--backup + --no-backup)"
  fi
}
check_backup_conflict --backup /tmp/a.bak --no-backup
check_backup_conflict --no-backup --backup /tmp/a.bak

# Restore mode rejects the prune-only options (#1129): each was parsed
# and then silently dropped by --restore-session — worst, --backup on a
# restore --apply run produced no backup and no warning. Each must die
# at the restore branch (exit 1 via die, before any restore work — the
# --db/--from paths here do not exist, proving the rejection precedes
# restore preflight), naming the option and that it does not apply to
# --restore-session, mirroring the existing --archive rejection.
check_restore_rejected() {
  local opt="$1"; shift
  local out rc
  out="$(bash "$PRUNE" --db /tmp/a.db --restore-session ses_a --from /tmp/a.src "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "prune restore $*: $opt in restore mode exited 0"
  elif ! printf '%s' "$out" | grep -q -- "$opt is a prune option; it does not apply to --restore-session"; then
    fail "prune restore $*: error does not name $opt as a prune option not applying to --restore-session: $out"
  else
    ok "prune restore $* rejected, naming $opt"
  fi
}
check_restore_rejected --backup --backup /tmp/a.bak
check_restore_rejected --no-backup --no-backup
check_restore_rejected --protect-days --protect-days 1
check_restore_rejected --protect-roots --protect-roots
check_restore_rejected --batch --batch 1

# Controls for the new guards: a single --backup, a lone --no-backup, and
# single uses of the guarded options still parse (an unknown option after
# them is reported as unknown, proving parsing continued past them).
check_parses_past() {
  local script="$1"; shift
  local out rc
  out="$(bash "$script" "$@" --bogus 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] || ! printf '%s' "$out" | grep -q "unknown option: --bogus"; then
    fail "$script $*: expected 'unknown option: --bogus', got rc=$rc: $out"
  else
    ok "$script $* parses (no false repeat/conflict rejection)"
  fi
}
check_parses_past "$PRUNE" --backup /tmp/a.bak
check_parses_past "$PRUNE" --no-backup
check_parses_past "$PRUNE" --protect-days 7 --archive /tmp/a.arc --batch 10
check_parses_past "$VAC" --into /tmp/a.out

# Controls: a valid value is consumed and parsing continues to the next
# token (an unknown option after it must be reported as unknown, proving
# the value was not confused with a flag and the flag was not swallowed).
check_consumes_value() {
  local script="$1"
  local out rc
  out="$(bash "$script" --db /tmp/args-test-nonexistent.db --bogus 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] || ! printf '%s' "$out" | grep -q "unknown option: --bogus"; then
    fail "$script --db <path> --bogus: expected 'unknown option: --bogus', got rc=$rc: $out"
  else
    ok "$script --db consumes a valid value"
  fi
}
check_consumes_value "$VAC"
check_consumes_value "$PRUNE"

# Control: vacuum happy path — a real scratch DB in --dry-run mode exits
# 0 and changes nothing.
if command -v sqlite3 >/dev/null; then
  scratch="$HOME/scratch.db"
  sqlite3 "$scratch" "create table t(x); insert into t values(1);"
  out="$(bash "$VAC" --db "$scratch" --dry-run 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "vacuum --dry-run on scratch DB exited $rc: $out"
  else
    ok "vacuum --dry-run happy path"
  fi
fi

# ---------------------------------------------------------------------------
# Preflight schema guard (#1051): prune's guard must assert every table the
# run later assumes (post-delete verification counts session/message/part/
# event_sequence; the eligibility SQL joins session on id/parent_id/
# time_updated), and vacuum must refuse up front for the tables its swap
# verification counts -- before any delete or compacted copy. A drifted DB
# used to be pruned first and fail mid-verification.
# ---------------------------------------------------------------------------
if command -v sqlite3 >/dev/null; then
  fx="$HOME/fx1051"; mkdir -p "$fx"

  # Hermetic wrt the host process table (#1451): the control below runs
  # prune in APPLY mode, whose check_not_running scans the real process
  # table via ps and refuses wherever opencode serve is running. The
  # harness scopes a ps double reporting no processes to this block only,
  # restoring PATH at the end so the rest of the suite still sees the
  # real ps.
  harness_ps_double_begin || exit 1

  # Full-schema fixture: one old session, 3 snapshots of msg_1 (seq 1-3,
  # so exactly seq 1-2 are eligible under --protect-days 0).
  mk_fixture() { # $1 = db path
    sqlite3 "$1" <<'SQL'
CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, time_updated INTEGER);
CREATE TABLE message(id TEXT);
CREATE TABLE part(id TEXT);
CREATE TABLE event(aggregate_id TEXT, type TEXT, seq INTEGER, data TEXT);
CREATE TABLE event_sequence(aggregate_id TEXT, seq INTEGER, owner_id TEXT);
INSERT INTO session VALUES ('ses_old', NULL, 1000);
INSERT INTO event VALUES ('ses_old','message.updated.1',1,'{"info":{"id":"msg_1"}}');
INSERT INTO event VALUES ('ses_old','message.updated.1',2,'{"info":{"id":"msg_1"}}');
INSERT INTO event VALUES ('ses_old','message.updated.1',3,'{"info":{"id":"msg_1"}}');
INSERT INTO event_sequence VALUES ('ses_old',1,NULL),('ses_old',2,NULL),('ses_old',3,NULL);
SQL
  }
  event_count() { sqlite3 "$1" "SELECT COUNT(*) FROM event;"; }

  # check_prune_refused <db> <expected message fragment>
  check_prune_refused() {
    local db="$1" want="$2" out rc
    out="$(bash "$PRUNE" --db "$db" --protect-days 0 --apply -y --no-backup 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      fail "prune on $db: exited 0, expected preflight refusal"
    elif ! printf '%s' "$out" | grep -q -- "$want"; then
      fail "prune on $db: refusal does not name '$want': $out"
    elif [ "$(event_count "$db")" != "3" ]; then
      fail "prune on $db: event rows changed despite refusal"
    else
      ok "prune refuses $db preflight ($want), rows unchanged"
    fi
  }

  db="$fx/missing-message.db"; mk_fixture "$db"; sqlite3 "$db" "DROP TABLE message;"
  check_prune_refused "$db" "message table missing"

  db="$fx/missing-part.db"; mk_fixture "$db"; sqlite3 "$db" "DROP TABLE part;"
  check_prune_refused "$db" "part table missing"

  db="$fx/missing-parent.db"; mk_fixture "$db"
  sqlite3 "$db" "CREATE TABLE session2(id TEXT PRIMARY KEY, time_updated INTEGER); INSERT INTO session2 SELECT id, time_updated FROM session; DROP TABLE session; ALTER TABLE session2 RENAME TO session;"
  check_prune_refused "$db" "session has no 'parent_id' column"

  # Control: the full-schema fixture prunes exactly as before (2 deleted,
  # newest kept, verification passes).
  db="$fx/full.db"; mk_fixture "$db"
  out="$(bash "$PRUNE" --db "$db" --protect-days 0 --apply -y --no-backup 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "prune on full-schema fixture exited $rc: $out"
  elif [ "$(event_count "$db")" != "1" ]; then
    fail "prune on full-schema fixture left $(event_count "$db") event rows, expected 1"
  else
    ok "prune full-schema fixture deletes only the 2 superseded snapshots"
  fi

  # Vacuum: missing message table refuses up front; no compacted copy.
  db="$fx/vac-missing-message.db"; mk_fixture "$db"; sqlite3 "$db" "DROP TABLE message;"
  out="$(bash "$VAC" --db "$db" -y 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "vacuum on $db: exited 0, expected preflight refusal"
  elif ! printf '%s' "$out" | grep -q -- "message table missing"; then
    fail "vacuum on $db: refusal does not name the missing table: $out"
  elif [ -e "$db.compact" ]; then
    fail "vacuum on $db: compacted copy was created despite refusal"
  else
    ok "vacuum refuses missing-message DB up front, no compacted copy"
  fi

  harness_ps_double_end
fi

# ---------------------------------------------------------------------------
# Shared probe matrix (lib/arg-probe.sh), extended to backup-prune (#1147):
# every bad invocation must exit 2 (the contract exit -- the migration onto
# lib/common.sh helpers moved vacuum/prune parse errors from die's exit 1
# to arg_die's exit 2), name the option, and have no side effect (all rows
# are parse-time, before any work). Accepted rows must exit 0.
# ---------------------------------------------------------------------------
# vacuum
probe_rejected "--bogus" "$VAC" --bogus
probe_rejected "--db requires a value" "$VAC" --db
probe_rejected "--db requires a value" "$VAC" --db --dry-run
probe_rejected "--into may be given only once" "$VAC" --into /tmp/a --into /tmp/b
probe_accepted "$VAC" --help
# prune
probe_rejected "--bogus" "$PRUNE" --bogus
probe_rejected "--db requires a value" "$PRUNE" --db
probe_rejected "--batch requires a value" "$PRUNE" --batch --apply
probe_rejected "--db may be given only once" "$PRUNE" --db /tmp/a --db /tmp/b
probe_rejected "--backup and --no-backup may not be combined" "$PRUNE" --backup /tmp/a --no-backup
probe_rejected "--backup and --no-backup may not be combined" "$PRUNE" --no-backup --backup /tmp/a
probe_rejected "--protect-days" "$PRUNE" --protect-days abc
probe_rejected "--protect-days" "$PRUNE" --protect-days 99999999999999999999999
probe_rejected "--batch" "$PRUNE" --batch 0
probe_rejected "--batch" "$PRUNE" --batch abc
probe_accepted "$PRUNE" --help
# backup-prune (new to the shared matrix in #1147)
probe_rejected "--bogus" "$BP" --bogus
probe_rejected "--dir requires a value" "$BP" --dir
probe_rejected "--keep requires a value" "$BP" --keep --apply
probe_rejected "--dir may be given only once" "$BP" --dir /tmp/a --dir /tmp/b
probe_rejected "--keep may be given only once" "$BP" --keep 1 --keep 2
probe_rejected "--apply and --dry-run may not be combined" "$BP" --apply --dry-run
probe_rejected "--apply and --dry-run may not be combined" "$BP" --dry-run --apply
probe_rejected "--keep" "$BP" --keep 0
probe_rejected "--keep" "$BP" --keep abc
probe_rejected "--keep" "$BP" --keep 99999999999999999999999
probe_rejected "--max-age-days" "$BP" --max-age-days abc
probe_rejected "--max-age-days" "$BP" --max-age-days 999999999999999999999
probe_accepted "$BP" --help
probe_accepted "$BP" --dir "$HOME" --keep 08

# ---------------------------------------------------------------------------
# Harness probe rows (lib/test-harness.sh, #1474): prove the mechanisms the
# migrated suites rely on. Each row runs a small child script with the
# parent's harness state scrubbed, so the child gets its own scratch root
# and its own stub bin, exactly as a fresh suite would.
# ---------------------------------------------------------------------------
HARNESS_LIB="$SELF_DIR/lib/test-harness.sh"

# probe_env <VAR=value...> -- run a command with the parent harness state
# removed, so the child's harness_init does not reuse the parent's root.
probe_env() {
  env -u HARNESS_ROOT -u HARNESS_STUB_BIN -u HARNESS_SAVED_PATH \
    -u HARNESS_SKIPS -u HARNESS_FAILURES -u HARNESS_CHECK "$@"
}

# check_harness_probe <name> <want-rc> <want-output> <check-mode 0|1> <script>
check_harness_probe() {
  local name="$1" want_rc="$2" want_out="$3" check="$4" body="$5"
  local out rc
  if [ "$check" = 1 ]; then
    out="$(probe_env HARNESS_CHECK=1 bash -s -- "$HARNESS_LIB" 2>&1 <<<"$body")"; rc=$?
  else
    out="$(probe_env bash -s -- "$HARNESS_LIB" 2>&1 <<<"$body")"; rc=$?
  fi
  if [ "$rc" -ne "$want_rc" ]; then
    fail "harness probe $name: exited $rc (want $want_rc): $out"
  elif ! printf '%s' "$out" | grep -q -- "$want_out"; then
    fail "harness probe $name: output does not contain '$want_out': $out"
  else
    ok "harness probe $name"
  fi
}

# A by-name stub runs where /usr/bin/env is not on the default PATH: the
# stub's shebang is the interpreter resolved when it was written, so the
# sandbox-shaped PATH cannot break it.
check_harness_probe "by-name stub without env on PATH" 0 "stub-ran" 0 '
. "$1"
harness_init || exit 10
harness_stub hello "echo stub-ran" || exit 11
saved="$PATH"
PATH="$HARNESS_STUB_BIN"; export PATH
command -v env >/dev/null 2>&1 && { echo "env is on PATH"; exit 12; }
hello || exit 13
PATH="$saved"; export PATH
'

# The ps double shadows a real ps, and the real one is back afterwards.
# Tolerates a sandbox with no real ps on PATH: the row then proves the
# double is what `ps` resolves to, and that PATH is restored after.
check_harness_probe "ps double shadows real ps" 0 "ps double shadows real ps" 0 '
. "$1"
harness_init || exit 10
before="$(command -v ps || true)"
harness_ps_double_begin || exit 11
double="$(command -v ps || true)"
case "$double" in
  "$HARNESS_STUB_BIN"/ps) ;;
  *) echo "double is not first on PATH: $double"; exit 12 ;;
esac
out="$(ps)" || { echo "double ps failed"; exit 13; }
[ -z "$out" ] || { echo "double ps printed: $out"; exit 14; }
harness_ps_double_end
after="$(command -v ps || true)"
[ "$after" = "$before" ] || { echo "ps not restored: $after != $before"; exit 15; }
echo "ps double shadows real ps (${before:-none on PATH})"
'

# A skip passes in direct mode, printing its reason; in check mode the
# same skip fails the suite at summary time.
HARNESS_SKIP_BODY='
. "$1"
harness_init || exit 10
harness_skip "no second filesystem"
harness_summary
'
check_harness_probe "direct-mode skip passes with reason" 0 "skip: no second filesystem" 0 "$HARNESS_SKIP_BODY"
check_harness_probe "check-mode skip fails" 1 "check mode forbids skips" 1 "$HARNESS_SKIP_BODY"

# The scratch root is gone after the child exits (the EXIT trap ran).
check_harness_cleanup() {
  local root rc
  root="$(probe_env bash -s -- "$HARNESS_LIB" 2>/dev/null <<'BODY'
. "$1"
harness_init || exit 10
case "$HOME" in
  "$HARNESS_ROOT"/*) ;;
  *) echo "HOME not under the scratch root: $HOME" >&2; exit 11 ;;
esac
printf '%s\n' "$HARNESS_ROOT"
BODY
)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "harness probe scratch cleanup: exited $rc"
  elif [ -e "$root" ]; then
    fail "harness probe scratch cleanup: $root survived exit"
  else
    ok "harness probe scratch cleanup removes the root on exit"
  fi
}
check_harness_cleanup

HARNESS_FAILURES="$failures"
[ "$failures" -eq 0 ] && echo "all argument-parser checks passed"
harness_summary
