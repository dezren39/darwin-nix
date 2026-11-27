#!/usr/bin/env bash
# Regression test for clean.sh's flag-shaped-value guards (#951).
#
# PR #939 (fix for #930) made clean.sh's value-taking options reject a
# flag-shaped next token — `--path --dry-run` used to swallow --dry-run
# as the path and run the cleanup for real — but added no test for
# clean.sh, so the guards could regress silently.
#
# The contract pinned here, for --path, --depth, and --docker-age:
#   <option> --dry-run  -> exit 2, "<option> requires a value" on
#                          stderr, and no side effects
#   valid values        -> accepted: the --only-unknown-scratch control
#                          run below parses all three options with real
#                          values and exits 0
#
# This drives the REAL clean.sh (no pasted copies) against temp dirs.
# The control uses --only-unknown-scratch so it exercises the parser and
# the post-parse judges, then sweeps only the isolated HOME's (empty)
# scratch root and exits — no docker/brew/git work runs.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/clean.sh"
# Shared environment and platform-double harness (design #1473 phase 2).
# shellcheck source=lib/test-harness.sh
. "$SELF_DIR/lib/test-harness.sh"
# Shared conformance probe matrix helpers (#1146, design #1145 phase 1).
# shellcheck source=lib/arg-probe.sh
. "$SELF_DIR/lib/arg-probe.sh"
# Shared conformance probe matrix for operation failures (design #1339 phase 1).
# shellcheck source=lib/outcome-probe.sh
. "$SELF_DIR/lib/outcome-probe.sh"


harness_init
TMP_ROOT="$HARNESS_ROOT"
# The control sweeps $HOME/.local/share/opencode/tmp; keep it absent so
# the sweep is a no-op regardless of the caller's real home.
unset DOCKER_AGE_DAYS DEPTH_LIMIT

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

VALID="$TMP_ROOT/valid"
mkdir -p "$VALID"
OTHER="$TMP_ROOT/other"
mkdir -p "$OTHER"

run() { # run <args...> — sets OUT, ERR, STATUS
  OUT="$(bash "$SCRIPT" "$@" 2>"$TMP_ROOT/err")"; STATUS=$?
  ERR="$(cat "$TMP_ROOT/err")"
}

snapshot() { find "$VALID" "$HOME" | sort; }
BEFORE="$(snapshot)"

# ─── Flag-shaped values are rejected at parse time ─────────────────────
for opt in --path --depth --docker-age; do
  run "$opt" --dry-run
  [ "$STATUS" -eq 2 ] || fail "$opt --dry-run exited $STATUS (want 2)"
  case "$ERR" in
    *"clean.sh: $opt requires a value"*) echo "ok: $opt --dry-run rejected, option named" ;;
    *) fail "$opt --dry-run did not name the option on stderr (got: $ERR)" ;;
  esac
done

# ─── Missing values are rejected at parse time (#970) ──────────
# PR #921 made the value-taking options reject a missing value (option
# last, or an empty string) with exit 2, but no suite pinned that branch:
# a refactor dropping the -n check would pass the flag-shaped runs above
# while a trailing option silently took an empty value. Each option must
# exit 2 naming itself for both shapes.
for opt in --path --depth --docker-age; do
  run "$opt"
  [ "$STATUS" -eq 2 ] || fail "$opt (trailing, no value) exited $STATUS (want 2)"
  case "$ERR" in
    *"clean.sh: $opt requires a value"*) echo "ok: $opt trailing rejected, option named" ;;
    *) fail "$opt (trailing, no value) did not name the option on stderr (got: $ERR)" ;;
  esac
  run "$opt" ""
  [ "$STATUS" -eq 2 ] || fail "$opt (empty value) exited $STATUS (want 2)"
  case "$ERR" in
    *"clean.sh: $opt requires a value"*) echo "ok: $opt empty value rejected, option named" ;;
    *) fail "$opt (empty value) did not name the option on stderr (got: $ERR)" ;;
  esac
done

# ─── Second / conflicting target is rejected at parse time (#1111) ────
# clean.sh used to assign every positional (and --path) to the single
# TARGET_PATH variable, so a second target silently discarded the first
# while the run exited 0 reporting success for a tree it never scanned.
# Every conflicting-target shape must exit 2 naming the unexpected
# argument, before any work runs (the snapshot check below covers the
# no-side-effects part for these runs too).
run --dry-run "$VALID" "$OTHER"
[ "$STATUS" -eq 2 ] || fail "second positional exited $STATUS (want 2)"
case "$ERR" in
  *"unexpected argument: $OTHER"*) echo "ok: second positional rejected, argument named" ;;
  *) fail "second positional did not name the argument on stderr (got: $ERR)" ;;
esac
run --dry-run --path "$VALID" "$OTHER"
[ "$STATUS" -eq 2 ] || fail "--path then positional exited $STATUS (want 2)"
case "$ERR" in
  *"unexpected argument: $OTHER"*) echo "ok: positional after --path rejected, argument named" ;;
  *) fail "positional after --path did not name the argument on stderr (got: $ERR)" ;;
esac
run --dry-run "$VALID" --path "$OTHER"
[ "$STATUS" -eq 2 ] || fail "positional then --path exited $STATUS (want 2)"
case "$ERR" in
  *"unexpected argument: --path"*) echo "ok: --path after positional rejected, option named" ;;
  *) fail "--path after positional did not name the option on stderr (got: $ERR)" ;;
esac
run --dry-run --path "$VALID" --path "$OTHER"
[ "$STATUS" -eq 2 ] || fail "repeated --path exited $STATUS (want 2)"
case "$ERR" in
  *"unexpected argument: --path"*) echo "ok: repeated --path rejected, option named" ;;
  *) fail "repeated --path did not name the option on stderr (got: $ERR)" ;;
esac

# --- Sibling conflict/repeat pairs are rejected at parse time (#1135) ---
# The 2026-10-29 batch guarded these pairs in the sibling scripts, but
# clean.sh still silently last-won them: --system/--no-system both wrote
# SCOPE_SET, --follow/--no-follow both wrote FOLLOW, and --depth /
# --docker-age assigned unconditionally. Every shape must exit 2 naming
# the conflict / only-once rule, mirroring git-maintain-repos /
# git-discover-repos.
for pair in "--system --no-system" "--no-system --system"; do
  # shellcheck disable=SC2086
  run --dry-run --path "$VALID" $pair
  [ "$STATUS" -eq 2 ] || fail "scope pair '$pair' exited $STATUS (want 2)"
  case "$ERR" in
    *"clean.sh: --system and --no-system may not be combined"*) echo "ok: scope pair '$pair' rejected as a conflict" ;;
    *) fail "scope pair '$pair' was not named as a conflict on stderr (got: $ERR)" ;;
  esac
done
for pair in "--follow --no-follow" "--no-follow --follow"; do
  # shellcheck disable=SC2086
  run --dry-run --path "$VALID" $pair
  [ "$STATUS" -eq 2 ] || fail "follow pair '$pair' exited $STATUS (want 2)"
  case "$ERR" in
    *"clean.sh: --follow and --no-follow may not be combined"*) echo "ok: follow pair '$pair' rejected as a conflict" ;;
    *) fail "follow pair '$pair' was not named as a conflict on stderr (got: $ERR)" ;;
  esac
done
for opt in --depth --docker-age; do
  run --dry-run --path "$VALID" "$opt" 1 "$opt" 2
  [ "$STATUS" -eq 2 ] || fail "repeated $opt exited $STATUS (want 2)"
  case "$ERR" in
    *"clean.sh: $opt may be given only once"*) echo "ok: repeated $opt rejected, option named" ;;
    *) fail "repeated $opt did not name the option on stderr (got: $ERR)" ;;
  esac
done
for flag in --system --no-system --follow --no-follow; do
  case "$flag" in
    --system) run "$flag" --only-unknown-scratch ;;
    *)        run --path "$VALID" "$flag" --only-unknown-scratch ;;
  esac
  [ "$STATUS" -eq 0 ] || fail "single $flag exited $STATUS (want 0, stderr: $ERR)"
  echo "ok: single $flag still accepted"
done

# ─── --system also judges the repo-scoped maintenance flags (#1711) ────
# The --system conflict judge only covered the discovery half of the
# repository vocabulary (--path/--recursive/--depth/--follow/--no-follow),
# so --quick, --expire-reflog and every --no-git-maintenance alias were
# silently dropped in system scope: their only consumers are the per-repo
# maintenance blocks, which DO_REPOS=0 never reaches. Erroring beats
# silently ignoring them, so each must be named in the same conflict, in
# either flag order, before any sweep runs (the snapshot check below
# covers the no-side-effects part).
for pair in "--system --quick" "--quick --system" \
            "--system --expire-reflog" "--expire-reflog --system" \
            "--system --no-git-maintenance" "--no-git-maintenance --system" \
            "--system --no-maintenance" "--no-maintenance --system" \
            "--system --no-git" "--no-git --system"; do
  # The flag under test is whichever token is not --system, so naming it
  # on stderr is actually proven (the judge always names --system itself).
  _pair_flag=""
  for _tok in $pair; do
    [ "$_tok" = "--system" ] || _pair_flag="$_tok"
  done
  # shellcheck disable=SC2086
  run --dry-run $pair
  [ "$STATUS" -eq 2 ] || fail "system/maintenance pair '$pair' exited $STATUS (want 2)"
  case "$ERR" in
    *"clean.sh: --system conflicts with repository-scoped flags:"*"$_pair_flag"*)
      echo "ok: system/maintenance pair '$pair' rejected, $_pair_flag named" ;;
    *) fail "system/maintenance pair '$pair' was not named as a conflict on stderr (got: $ERR)" ;;
  esac
done
unset _pair_flag _tok
# All of them at once are reported together, in the order given.
run --dry-run --system --quick --expire-reflog --no-git
[ "$STATUS" -eq 2 ] || fail "--system with every maintenance flag exited $STATUS (want 2)"
case "$ERR" in
  *"conflicts with repository-scoped flags: --quick --expire-reflog --no-git"*)
    echo "ok: every maintenance flag named together on stderr" ;;
  *) fail "combined maintenance flags not named on stderr (got: $ERR)" ;;
esac
# The same flags stay live outside system scope: --no-system with a target
# and --only-unknown-scratch parses them and exits 0 (the sudo re-exec
# section below covers their behaviour; this pins only the parse).
for flag in --quick --expire-reflog --no-git-maintenance --no-maintenance --no-git; do
  run --no-system --path "$VALID" --only-unknown-scratch "$flag"
  [ "$STATUS" -eq 0 ] || fail "$flag under --no-system exited $STATUS (want 0, stderr: $ERR)"
  echo "ok: $flag still accepted under --no-system"
done

# ─── No side effects from the rejected runs ────────────────────────────
if [ "$(snapshot)" = "$BEFORE" ]; then
  echo "ok: rejected runs left the fixture tree unchanged"
else
  fail "rejected runs changed the fixture tree"
fi

# ─── Valid-value control ───────────────────────────────────────────────
run --path "$VALID" --depth 2 --docker-age 7 --only-unknown-scratch
[ "$STATUS" -eq 0 ] || fail "valid-value control exited $STATUS (stderr: $ERR)"
case "$OUT" in
  *"nothing >=500MB"*) echo "ok: valid values parse and the control run exits 0" ;;
  *) fail "valid-value control output changed (got: $OUT)" ;;
esac

# ─── Portable stat: BSD-stat shim regression (#1068) ──────────────────
# clean.sh is a macOS tool, but three sites used GNU-only `stat -c`;
# BSD stat rejects -c, 2>/dev/null swallowed it, and the values came
# back empty: the pytest newest-run guard never fired and the
# unknown-scratch report always printed "unknown" dates. The shared
# harness double rejects -c exactly as macOS stat does and implements
# the BSD -f forms clean.sh's portable helpers use.
harness_stat_double_begin || { fail "could not start shared stat double"; exit 1; }
LSOF_STUB_DIR="$TMP_ROOT/lsof-stub"
mkdir -p "$LSOF_STUB_DIR"
printf '#!/bin/sh\nexit 1\n' > "$LSOF_STUB_DIR/lsof"
chmod +x "$LSOF_STUB_DIR/lsof"

SCRATCH_BASE="$HOME/.local/share/opencode/tmp"
mkdir -p "$SCRATCH_BASE"

# Unknown-scratch report dates populate under BSD and GNU stat alike.
# Flagged-only mode (--only-unknown-scratch, no --prune): the fixture
# survives both runs, so the same entry serves the BSD and GNU passes.
UENTRY="$SCRATCH_BASE/zzscratch1068"
mkdir -p "$UENTRY"
dd if=/dev/zero of="$UENTRY/blob" bs=1024 count=1536 2>/dev/null
touch -d '2020-01-02 03:04:05' "$UENTRY"
for mode in bsd gnu; do
  if [ "$mode" = "bsd" ]; then
    OUT="$(PATH="$LSOF_STUB_DIR:$PATH" UNKNOWN_SCRATCH_MIN_MB=1 UNKNOWN_SCRATCH_STALE_DAYS=1 bash "$SCRIPT" --only-unknown-scratch 2>"$TMP_ROOT/err")"; STATUS=$?
  else
    harness_stat_double_end
    OUT="$(PATH="$LSOF_STUB_DIR:$PATH" UNKNOWN_SCRATCH_MIN_MB=1 UNKNOWN_SCRATCH_STALE_DAYS=1 bash "$SCRIPT" --only-unknown-scratch 2>"$TMP_ROOT/err")"; STATUS=$?
  fi
  ERR="$(cat "$TMP_ROOT/err")"
  [ "$STATUS" -eq 0 ] || fail "unknown-scratch ($mode stat) exited $STATUS (stderr: $ERR)"
  ULINE="$(printf '%s\n' "$OUT" | grep 'zzscratch1068' || true)"
  [ -n "$ULINE" ] || { fail "unknown-scratch ($mode stat): fixture not reported"; continue; }
  case "$ULINE" in
    *"2020-01-02 03:04:05"*) echo "ok: unknown-scratch ($mode stat) report shows the real modified date" ;;
    *) fail "unknown-scratch ($mode stat): modified date not populated (line: $ULINE)" ;;
  esac
  case "$ULINE" in
    *unknown*) fail "unknown-scratch ($mode stat): report still shows unknown dates (line: $ULINE)" ;;
    *) echo "ok: unknown-scratch ($mode stat) report shows a created date" ;;
  esac
done
harness_stat_double_end

# ─── Unknown-scratch sweep honors VAR_FOLDERS_ROOT (#1865) ───────
# Both unknown-scratch scans (the --only-unknown-scratch early exit
# and the full-run catch-all) used to iterate the literal
# /private/var/folders/*/*/T, ignoring the VAR_FOLDERS_ROOT seam
# (#1346) -- so fixtures could not exercise the var/folders leg, and
# --prune-unknown-scratch could delete host entries outside the
# caller's intended root. Fixture: an eligible entry under a
# configured root's */*/T, and a twin under an unconfigured root.
VF_ROOT="$TMP_ROOT/vf-root-1865"
VF_T="$VF_ROOT/ab/cd/T"
mkdir -p "$VF_T"
VF_ENTRY="$VF_T/zzvf1865"
mkdir -p "$VF_ENTRY"
dd if=/dev/zero of="$VF_ENTRY/blob" bs=1024 count=1536 2>/dev/null
touch -d '2020-01-02 03:04:05' "$VF_ENTRY"
VF_OTHER="$TMP_ROOT/vf-other-1865/ef/gh/T"
mkdir -p "$VF_OTHER"
VF_OTHER_ENTRY="$VF_OTHER/zzvf1865other"
mkdir -p "$VF_OTHER_ENTRY"
dd if=/dev/zero of="$VF_OTHER_ENTRY/blob" bs=1024 count=1536 2>/dev/null
touch -d '2020-01-02 03:04:05' "$VF_OTHER_ENTRY"
OUT="$(PATH="$LSOF_STUB_DIR:$PATH" VAR_FOLDERS_ROOT="$VF_ROOT" UNKNOWN_SCRATCH_MIN_MB=1 UNKNOWN_SCRATCH_STALE_DAYS=1 bash "$SCRIPT" --only-unknown-scratch 2>"$TMP_ROOT/err")"; STATUS=$?
ERR="$(cat "$TMP_ROOT/err")"
[ "$STATUS" -eq 0 ] || fail "vf-root (#1865): --only-unknown-scratch exited $STATUS (stderr: $ERR)"
case "$OUT" in
  *zzvf1865*) echo "ok: vf-root (#1865): --only-unknown-scratch reports the configured root's entry" ;;
  *) fail "vf-root (#1865): configured root's entry not reported (got: $OUT)" ;;
esac
[ -d "$VF_ENTRY" ] || fail "vf-root (#1865): flagged-only run deleted the fixture entry"
OUT="$(PATH="$LSOF_STUB_DIR:$PATH" VAR_FOLDERS_ROOT="$VF_ROOT" UNKNOWN_SCRATCH_MIN_MB=1 UNKNOWN_SCRATCH_STALE_DAYS=1 bash "$SCRIPT" --only-unknown-scratch --prune-unknown-scratch 2>"$TMP_ROOT/err")"; STATUS=$?
ERR="$(cat "$TMP_ROOT/err")"
[ "$STATUS" -eq 0 ] || fail "vf-root prune (#1865): exited $STATUS (stderr: $ERR)"
[ -d "$VF_ENTRY" ] && fail "vf-root prune (#1865): eligible entry under the configured root survived" || echo "ok: vf-root prune (#1865): eligible entry under the configured root deleted"
[ -d "$VF_OTHER_ENTRY" ] || fail "vf-root prune (#1865): entry under an UNCONFIGURED root was deleted"
echo "ok: vf-root prune (#1865): unconfigured root untouched"

# ─── Short-lived / ad-hoc-postgres / pytest sweeps honor VAR_FOLDERS_ROOT (#1977) ───
# Three more var/folders legs still iterated the literal
# /private/var/folders/*/*/T after #1865: the pytest tidy base list,
# the short-lived-scratch loop, and the ad-hoc-postgres loop -- so
# fixtures could not exercise them through the seam, and a real run
# could touch host entries outside the caller's intended root.
# Fixture (mirrors the #1865 twin-root shape): eligible entries under
# a configured root's */*/T, twins under an unconfigured root. Driven
# with --system --dry-run like the pytest-guard block below, so del()
# reports instead of removing: the configured root's entries must be
# scheduled, the unconfigured root's must not even be named.
VF1977_ROOT="$TMP_ROOT/vf-root-1977"
VF1977_T="$VF1977_ROOT/ab/cd/T"
mkdir -p "$VF1977_T/mcpx-fake-1977" "$VF1977_T/zzpg1977" "$VF1977_T/pytest-of-1977/pytest-1" "$VF1977_T/pytest-of-1977/pytest-2"
touch "$VF1977_T/zzpg1977/PG_VERSION"
ln -s pytest-2 "$VF1977_T/pytest-of-1977/pytest-current"
touch -d '10 hours ago' "$VF1977_T/mcpx-fake-1977" "$VF1977_T/zzpg1977/PG_VERSION" "$VF1977_T/zzpg1977" "$VF1977_T/pytest-of-1977/pytest-1"
touch -d '6 hours ago' "$VF1977_T/pytest-of-1977/pytest-2"
VF1977_OTHER_T="$TMP_ROOT/vf-other-1977/ef/gh/T"
mkdir -p "$VF1977_OTHER_T/mcpx-fake-1977other" "$VF1977_OTHER_T/zzpg1977other" "$VF1977_OTHER_T/pytest-of-1977other/pytest-1" "$VF1977_OTHER_T/pytest-of-1977other/pytest-2"
touch "$VF1977_OTHER_T/zzpg1977other/PG_VERSION"
ln -s pytest-2 "$VF1977_OTHER_T/pytest-of-1977other/pytest-current"
touch -d '10 hours ago' "$VF1977_OTHER_T/mcpx-fake-1977other" "$VF1977_OTHER_T/zzpg1977other/PG_VERSION" "$VF1977_OTHER_T/zzpg1977other" "$VF1977_OTHER_T/pytest-of-1977other/pytest-1"
touch -d '6 hours ago' "$VF1977_OTHER_T/pytest-of-1977other/pytest-2"
OUT="$(PATH="$LSOF_STUB_DIR:$PATH" VAR_FOLDERS_ROOT="$VF1977_ROOT" PYTEST_KEEP_HOURS=4 bash "$SCRIPT" --system --dry-run 2>"$TMP_ROOT/err")"; STATUS=$?
ERR="$(cat "$TMP_ROOT/err")"
[ "$STATUS" -eq 0 ] || fail "vf-root (#1977): --system --dry-run exited $STATUS (stderr: $ERR)"
if grep -q 'would delete: .*vf-root-1977/ab/cd/T/mcpx-fake-1977$' <<<"$OUT"; then
  echo "ok: vf-root (#1977): short-lived sweep scans the configured root"
else
  fail "vf-root (#1977): short-lived sweep did not schedule the configured root's entry"
fi
if grep -q 'would remove (postgres data dir, idle >8h): .*vf-root-1977/ab/cd/T/zzpg1977$' <<<"$OUT"; then
  echo "ok: vf-root (#1977): ad-hoc-postgres sweep scans the configured root"
else
  fail "vf-root (#1977): ad-hoc-postgres sweep did not schedule the configured root's cluster"
fi
if grep -q 'would delete: .*vf-root-1977/ab/cd/T/pytest-of-1977/pytest-1$' <<<"$OUT"; then
  echo "ok: vf-root (#1977): pytest tidy scans the configured root"
else
  fail "vf-root (#1977): pytest tidy did not schedule the configured root's older run"
fi
if grep -q 'vf-other-1977' <<<"$OUT"; then
  fail "vf-root (#1977): unconfigured root was scanned"
else
  echo "ok: vf-root (#1977): unconfigured root not scanned"
fi
[ -d "$VF1977_OTHER_T/mcpx-fake-1977other" ] && [ -d "$VF1977_OTHER_T/zzpg1977other" ] && [ -d "$VF1977_OTHER_T/pytest-of-1977other/pytest-1" ] || fail "vf-root (#1977): unconfigured root entries were touched"
echo "ok: vf-root (#1977): unconfigured root untouched"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)" >&2; exit 1; }
echo "truncated diag passed"
