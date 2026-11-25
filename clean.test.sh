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

# Pytest newest-run guard fires under BSD and GNU stat alike. Both
# runs are older than PYTEST_KEEP_HOURS, so only the guard keeps the
# newest (pytest-2). --dry-run makes del() report instead of remove:
# under the #1068 bug pytest-2 appears in the would-delete list.
PTDIR="$SCRATCH_BASE/pytest-of-fixture"
mkdir -p "$PTDIR/pytest-1" "$PTDIR/pytest-2"
touch -d '10 hours ago' "$PTDIR/pytest-1"
touch -d '6 hours ago' "$PTDIR/pytest-2"
ln -s pytest-2 "$PTDIR/pytest-current"
for mode in bsd gnu; do
  if [ "$mode" = "bsd" ]; then
    harness_stat_double_begin || fail "could not restart shared stat double"
    OUT="$(PATH="$PATH" PYTEST_KEEP_HOURS=4 TMPDIR="$SCRATCH_BASE" bash "$SCRIPT" --system --dry-run 2>"$TMP_ROOT/err")"; STATUS=$?
  else
    harness_stat_double_end
    OUT="$(PYTEST_KEEP_HOURS=4 TMPDIR="$SCRATCH_BASE" bash "$SCRIPT" --system --dry-run 2>"$TMP_ROOT/err")"; STATUS=$?
  fi
  ERR="$(cat "$TMP_ROOT/err")"
  [ "$STATUS" -eq 0 ] || fail "pytest guard ($mode stat): --system --dry-run exited $STATUS (stderr: $ERR)"
  # Line-exact, fixture-path-pinned matching (#1314): the old whole-output
  # globs (*"would delete:"*pytest-2*) matched the host's real
  # /tmp/pytest-of-user/pytest-21 and pytest-22 would-delete lines --
  # "pytest-2" is a substring of both, and a glob spans lines -- so the
  # suite failed on any machine with real pytest runs in /tmp even though
  # the guard fired. Match a single would-delete line naming this
  # fixture's run directory, end-anchored so pytest-1x/pytest-2x host
  # runs cannot trip it either. Here-strings, not pipes: grep -q in a
  # pipeline under pipefail can SIGPIPE the writer on large output.
  if grep -q 'would delete: .*pytest-of-fixture/pytest-1$' <<<"$OUT"; then
    echo "ok: pytest guard ($mode stat) schedules the older run for deletion"
  else
    fail "pytest guard ($mode stat): older pytest-1 not scheduled for deletion"
  fi
  if grep -q 'would delete: .*pytest-of-fixture/pytest-2$' <<<"$OUT"; then
    fail "pytest guard ($mode stat): newest pytest-2 scheduled for deletion -- guard did not fire"
  else
    echo "ok: pytest guard ($mode stat) preserves the newest run"
  fi
  [ -e "$PTDIR/pytest-current" ] || fail "pytest guard ($mode stat): pytest-current dangling after the run"
done
harness_stat_double_end

# ─── --tmpdir sweep failure surfaces in clean.sh's result (#1270) ──
# var-folders-clean.sh exits 1 naming failed deletions (#1262), but
# clean.sh used to call it bare (no set -e anywhere), so a partially
# failed --tmpdir sweep still ended at exit 0. Drive the REAL sweep
# through the VAR_FOLDERS_ROOT seam with the #1262 rm shim (one
# entry, aa, fails regardless of the suite's privileges): clean.sh
# must exit non-zero, name the sweep as failed, leave aa in place, and
# still sweep the rest. The success control must exit 0.
# The runs use --only-tmpdir, NOT --system --tmpdir: HALF 1 does real
# host cleanup (absolute-path brew, /Library/Caches/Homebrew, Trash)
# before it reaches the sweep, so a --system run would delete host
# data merely by running this suite on a developer machine.
# --only-tmpdir runs just the shared sweep and exits with its result.
vf="$TMP_ROOT/varfolders"
mkdir -p "$vf/aa" "$vf/bb" "$vf/zz"
touch "$vf/aa/file" "$vf/zz/file2"
shim_dir="$TMP_ROOT/rm-shim"
mkdir -p "$shim_dir"
real_rm="$(command -v rm)"
cat > "$shim_dir/rm" <<SHIM_EOF
#!$(command -v bash)
for arg in "\$@"; do
  case "\$arg" in
    */aa) echo "rm: cannot remove (shimmed failure)" >&2; exit 1 ;;
  esac
done
exec $real_rm "\$@"
SHIM_EOF
chmod +x "$shim_dir/rm"
OLD_PATH="$PATH"
export VAR_FOLDERS_ROOT="$vf"
PATH="$shim_dir:$PATH"
run --only-tmpdir --no-sudo
PATH="$OLD_PATH"
[ "$STATUS" -ne 0 ] || fail "--tmpdir with a failing deletion exited $STATUS (want non-zero)"
case "$ERR" in
  *"/private/var/folders sweep failed"*) echo "ok: --tmpdir failure named the sweep as failed" ;;
  *) fail "--tmpdir failure did not name the sweep on stderr (got: $ERR)" ;;
esac
case "$ERR" in
  *"clean.sh: 1 operation(s) failed"*"$vf"*)
    echo "ok: --tmpdir failure includes the counted outcome summary" ;;
  *) fail "--tmpdir failure did not include the counted summary (got: $ERR)" ;;
esac
[ -e "$vf/aa/file" ] && echo "ok: shimmed entry left in place" || fail "shimmed entry was removed anyway"
[ ! -e "$vf/bb" ] && [ ! -e "$vf/zz/file2" ] && echo "ok: rest of the sweep still ran" || fail "sweep stopped at the failure"
# Success control: same path, no shim -- everything swept, exit 0.
vf2="$TMP_ROOT/varfolders-ok"
mkdir -p "$vf2/aa" "$vf2/zz"
touch "$vf2/aa/file" "$vf2/zz/file2"
OLD_PATH="$PATH"
export VAR_FOLDERS_ROOT="$vf2"
run --only-tmpdir --no-sudo
PATH="$OLD_PATH"
unset VAR_FOLDERS_ROOT
[ "$STATUS" -eq 0 ] || fail "--tmpdir success control exited $STATUS (want 0, stderr: $ERR)"
[ ! -e "$vf2/aa" ] && [ ! -e "$vf2/zz/file2" ] && echo "ok: success control swept the fixture" || fail "success control did not sweep the fixture"

# ─── Tidy archive-move failures surface in clean.sh's result (#1337) ──
# tidy_file_to_bucket / tidy_dir_to_bucket used to run
# `mkdir -p "$dest" && mv "$entry" "$dest/" 2>/dev/null` unchecked, so a
# failed archive move left the entry in place, printed nothing, and the
# run exited 0. Drive the real tidy pass (repo half only, fixture HOME)
# with a PATH-stub mv that always fails: clean.sh must warn naming the
# entry, print the failure count, exit non-zero, and leave the entry in
# place. The success control (real mv) must archive it and exit 0.
# The fixture HOME's basename must be a real user: clean.sh derives
# CALLER_USER from it, so this section runs under its own HOME named
# after the current user. Discovery must still scan ONLY this fixture
# HOME: clean.sh omits --user when HOME already equals
# CALLER_USER_HOME, because git-discover-repos --user resolves the
# passwd home and would clean the real user's actual repositories
# (Codex P1 on PR #1342). The "0 repos" assertion below pins that:
# on any developer machine the real home holds repos, so a discovery
# leak makes the count non-zero.
tidy_home="$TMP_ROOT/$(id -un)"
tidy_base="$tidy_home/.local/share/opencode/tmp/opencode"
mkdir -p "$tidy_base"
touch "$tidy_base/loose1.txt"
# Isolate the macOS scratch roots too (#1346): point VAR_FOLDERS_ROOT at an
# empty fixture so neither clean.sh's opencode tidy loop nor
# git-discover-repos' seed scan can reach real host /private/var/folders
# roots on macOS. Unset again after this section.
vf_empty="$TMP_ROOT/varfolders-empty"
mkdir -p "$vf_empty"
export VAR_FOLDERS_ROOT="$vf_empty"
orig_home="$HOME"
export HOME="$tidy_home"
mv_shim_dir="$TMP_ROOT/mv-shim"
mkdir -p "$mv_shim_dir"
printf '#!%s\nexit 1\n' "$(command -v bash)" > "$mv_shim_dir/mv"
chmod +x "$mv_shim_dir/mv"
OLD_PATH="$PATH"
PATH="$mv_shim_dir:$PATH"
run --no-system --no-sudo --no-git-maintenance
PATH="$OLD_PATH"
[ "$STATUS" -ne 0 ] || fail "tidy with a failing mv exited $STATUS (want non-zero)"
case "$ERR" in
  *"could not file away"*"loose1.txt"*) echo "ok: tidy failure warned naming the entry" ;;
  *) fail "tidy failure did not name the entry on stderr (got: $ERR)" ;;
esac
case "$ERR" in
  *"1 archive move(s) failed"*) echo "ok: tidy failure summary named the count" ;;
  *) fail "tidy failure summary did not name the count on stderr (got: $ERR)" ;;
esac
[ -e "$tidy_base/loose1.txt" ] && echo "ok: failed entry left in place" || fail "failed entry was archived anyway"
case "$OUT" in
  *"0 repos, 0 worktrees"*) echo "ok: tidy run discovery stayed inside the fixture HOME" ;;
  *) fail "tidy run discovery was not isolated to the fixture HOME (got: $OUT)" ;;
esac
# Success control: same fixture, real mv -- archived, exit 0.
run --no-system --no-sudo --no-git-maintenance
[ "$STATUS" -eq 0 ] || fail "tidy success control exited $STATUS (want 0, stderr: $ERR)"
[ ! -e "$tidy_base/loose1.txt" ] && find "$tidy_base/_loose" -name loose1.txt | grep -q . && echo "ok: success control archived the entry" || fail "success control did not archive the entry"
export HOME="$orig_home"
unset VAR_FOLDERS_ROOT

# ─── opencode scratch roots follow VAR_FOLDERS_ROOT (#1346) ──
# Positive pin: a fixture var-folders root holding a loose file must be
# tidied, and a git repo under it must be discovered -- proving both
# enumeration sites follow the override instead of the hardcoded
# /private/var/folders. Negative pin: with the override pointing at an
# empty dir, the same fixture content is invisible -- proving a test run
# pointed at a fixture can never reach real host roots. Production
# behaviour is unchanged when the override is unset (same default root).
vf_iso="$TMP_ROOT/varfolders-isolated"
vf_oc="$vf_iso/aa/bb/T/opencode"
mkdir -p "$vf_oc"
touch "$vf_oc/loose-iso.txt"
mkdir -p "$vf_oc/iso-repo"
git -C "$vf_oc/iso-repo" init -q 2>/dev/null || fail "could not init fixture scratch repo"
export VAR_FOLDERS_ROOT="$vf_iso"
iso_home="$TMP_ROOT/iso-home"
mkdir -p "$iso_home"
disc_out="$(HOME="$iso_home" bash "$SELF_DIR/git-discover-repos" --auto --repos-only 2>"$TMP_ROOT/iso-disc-err")"; disc_rc=$?
[ "$disc_rc" -eq 0 ] || fail "discovery against fixture var root exited $disc_rc: $(cat "$TMP_ROOT/iso-disc-err")"
case "$disc_out" in
  *"$vf_oc/iso-repo"*) echo "ok: discovery follows VAR_FOLDERS_ROOT to the fixture scratch root" ;;
  *) fail "discovery did not find the fixture scratch repo (got: $disc_out)" ;;
esac
vf_miss="$TMP_ROOT/varfolders-miss"
mkdir -p "$vf_miss"
export VAR_FOLDERS_ROOT="$vf_miss"
disc_out="$(HOME="$iso_home" bash "$SELF_DIR/git-discover-repos" --auto --repos-only 2>"$TMP_ROOT/iso-disc-err")"; disc_rc=$?
[ "$disc_rc" -eq 0 ] || fail "discovery against empty var root exited $disc_rc: $(cat "$TMP_ROOT/iso-disc-err")"
case "$disc_out" in
  *"$vf_oc/iso-repo"*) fail "discovery leaked the fixture scratch repo with the override pointed elsewhere" ;;
  *) echo "ok: discovery pointed elsewhere never enumerates the fixture scratch root" ;;
esac
# Tidy the fixture var root for real: the loose file must be filed away.
export VAR_FOLDERS_ROOT="$vf_iso"
tidy_iso_home="$TMP_ROOT/$(id -un)-iso"
tidy_iso_base="$tidy_iso_home/.local/share/opencode/tmp/opencode"
mkdir -p "$tidy_iso_base"
orig_home2="$HOME"
export HOME="$tidy_iso_home"
run --no-system --no-sudo --no-git-maintenance
[ "$STATUS" -eq 0 ] || fail "tidy against fixture var root exited $STATUS (want 0, stderr: $ERR)"
[ ! -e "$vf_oc/loose-iso.txt" ] && find "$vf_oc/_loose" -name loose-iso.txt | grep -q . && echo "ok: tidy filed away the fixture scratch loose file" || fail "tidy did not file away the fixture scratch loose file"
export HOME="$orig_home2"
unset VAR_FOLDERS_ROOT

# ─── --only-tmpdir survives the privilege re-exec (Codex P1 on #1273) ──
# The parser consumes "$@" before the privilege block, and ONLY_TMPDIR
# was neither skipped past brew_cleanup nor carried into the sudo
# re-exec -- so a non-root \`clean.sh --only-tmpdir\` (no --no-sudo) ran
# brew maintenance, then re-executed WITHOUT the flag and performed the
# default full cleanup instead of just the sweep. Stub sudo: it records
# its argv + the ONLY_TMPDIR it was handed and exits 0 without running
# anything, so this is safe anywhere; as root the privilege block is
# skipped entirely and so is this section.
if [ "$(id -u)" -ne 0 ]; then
  sudo_stub_dir="$TMP_ROOT/sudo-stub"
  mkdir -p "$sudo_stub_dir"
  export SUDO_STUB_LOG="$TMP_ROOT/sudo-stub.log"
  : > "$SUDO_STUB_LOG"
  {
    printf '#!%s\n' "$(command -v bash)"
    cat <<'STUB_EOF'
{
  printf 'args: %s\n' "$*"
  printf 'ONLY_TMPDIR=%s\n' "${ONLY_TMPDIR:-unset}"
  printf 'NIX_KEEP_DAYS=%s\n' "${NIX_KEEP_DAYS:-unset}"
  printf 'PYTEST_KEEP_HOURS=%s\n' "${PYTEST_KEEP_HOURS:-unset}"
  printf 'VSCODE_PRUNE_HEAVY=%s\n' "${VSCODE_PRUNE_HEAVY:-unset}"
  printf 'PRUNE_UNKNOWN_SCRATCH=%s\n' "${PRUNE_UNKNOWN_SCRATCH:-unset}"
} >> "$SUDO_STUB_LOG"
exit 0
STUB_EOF
  } > "$sudo_stub_dir/sudo"
  chmod +x "$sudo_stub_dir/sudo"
  OLD_PATH="$PATH"
  PATH="$sudo_stub_dir:$PATH"
  run --only-tmpdir
  PATH="$OLD_PATH"
  [ "$STATUS" -eq 0 ] || fail "--only-tmpdir sudo re-exec exited $STATUS (want 0, stderr: $ERR)"
  case "$(cat "$SUDO_STUB_LOG")" in
    *"ONLY_TMPDIR=1"*) echo "ok: --only-tmpdir carried into the sudo re-exec" ;;
    *) fail "--only-tmpdir did not reach the sudo re-exec (stub log: $(cat "$SUDO_STUB_LOG"))" ;;
  esac
  case "$(cat "$SUDO_STUB_LOG")" in
    *"--preserve-env="*ONLY_TMPDIR*) echo "ok: ONLY_TMPDIR named in --preserve-env" ;;
    *) fail "ONLY_TMPDIR missing from --preserve-env (stub log: $(cat "$SUDO_STUB_LOG"))" ;;
  esac
  case "$OUT" in
    *"brew cleanup"*) fail "--only-tmpdir ran pre-sudo brew cleanup" ;;
    *) echo "ok: --only-tmpdir skipped pre-sudo brew cleanup" ;;
  esac
  # Validated tunables survive the same re-exec (#1309): the re-exec
  # assigned and --preserve-env-listed only 10 of the 18 validated
  # tunables, so the rest were dropped by sudo env_reset and the root
  # run silently used defaults (NIX_KEEP_DAYS=0 never took effect).
  : > "$SUDO_STUB_LOG"
  OLD_PATH="$PATH"
  PATH="$sudo_stub_dir:$PATH"
  export NIX_KEEP_DAYS=0 PYTEST_KEEP_HOURS=1 VSCODE_PRUNE_HEAVY=1
  run --only-tmpdir
  PATH="$OLD_PATH"
  unset NIX_KEEP_DAYS PYTEST_KEEP_HOURS VSCODE_PRUNE_HEAVY
  [ "$STATUS" -eq 0 ] || fail "tunable sudo re-exec exited $STATUS (want 0, stderr: $ERR)"
  case "$(cat "$SUDO_STUB_LOG")" in
    *"NIX_KEEP_DAYS=0"*) echo "ok: NIX_KEEP_DAYS=0 carried into the sudo re-exec" ;;
    *) fail "NIX_KEEP_DAYS=0 did not reach the sudo re-exec (stub log: $(cat "$SUDO_STUB_LOG"))" ;;
  esac
  case "$(cat "$SUDO_STUB_LOG")" in
    *"PYTEST_KEEP_HOURS=1"*) echo "ok: PYTEST_KEEP_HOURS=1 carried into the sudo re-exec" ;;
    *) fail "PYTEST_KEEP_HOURS=1 did not reach the sudo re-exec (stub log: $(cat "$SUDO_STUB_LOG"))" ;;
  esac
  case "$(cat "$SUDO_STUB_LOG")" in
    *"VSCODE_PRUNE_HEAVY=1"*) echo "ok: VSCODE_PRUNE_HEAVY=1 carried into the sudo re-exec" ;;
    *) fail "VSCODE_PRUNE_HEAVY=1 did not reach the sudo re-exec (stub log: $(cat "$SUDO_STUB_LOG"))" ;;
  esac
  # The --preserve-env list itself (the stub's args line, not the env
  # lines below it) is the discriminating check: real sudo env_reset
  # drops any carried value whose name is not listed there.
  _args_line="$(grep '^args:' "$SUDO_STUB_LOG")"
  for _tunable in NIX_KEEP_DAYS NIX_KEEP_GENS SHORT_SCRATCH_STALE_HOURS PG_SCRATCH_STALE_HOURS ACTIVE_ARTIFACT_STALE_HOURS PYTEST_KEEP_HOURS UNKNOWN_SCRATCH_MIN_MB UNKNOWN_SCRATCH_STALE_DAYS VSCODE_PRUNE_HEAVY; do
    case "$_args_line" in
      *",$_tunable,"*|*",$_tunable "*) echo "ok: $_tunable named in --preserve-env" ;;
      *) fail "$_tunable missing from --preserve-env (args: $_args_line)" ;;
    esac
  done
  # CLI flags survive the same re-exec (#1313): the parser consumed
  # "$@" before the privilege block, so the root run re-parsed an empty
  # argument list and silently widened a scoped run (one target,
  # --no-system, no git maintenance) to the default full-machine run.
  # clean.sh now captures the original arguments before parsing and
  # re-passes them; the stub's args line must show every flag below.
  : > "$SUDO_STUB_LOG"
  OLD_PATH="$PATH"
  PATH="$sudo_stub_dir:$PATH"
  run --no-system --path "$VALID" --depth 2 --follow --no-git-maintenance --quick --prune-unknown-scratch
  PATH="$OLD_PATH"
  [ "$STATUS" -eq 0 ] || fail "flag-survival sudo re-exec exited $STATUS (want 0, stderr: $ERR)"
  _args_line="$(grep '^args:' "$SUDO_STUB_LOG")"
  for _flag in "--no-system" "--path $VALID" "--depth 2" "--follow" "--no-git-maintenance" "--quick" "--prune-unknown-scratch"; do
    case "$_args_line" in
      *"$_flag"*) echo "ok: $_flag reaches the sudo re-exec" ;;
      *) fail "$_flag missing from the sudo re-exec (args: $_args_line)" ;;
    esac
  done
  unset _flag _args_line
  case "$(cat "$SUDO_STUB_LOG")" in
    *"PRUNE_UNKNOWN_SCRATCH=1"*) echo "ok: PRUNE_UNKNOWN_SCRATCH=1 carried into the sudo re-exec" ;;
    *) fail "PRUNE_UNKNOWN_SCRATCH did not reach the sudo re-exec (stub log: $(cat "$SUDO_STUB_LOG"))" ;;
  esac
  _args_line="$(grep '^args:' "$SUDO_STUB_LOG")"
  case "$_args_line" in
    *",PRUNE_UNKNOWN_SCRATCH,"*) echo "ok: PRUNE_UNKNOWN_SCRATCH named in --preserve-env" ;;
    *) fail "PRUNE_UNKNOWN_SCRATCH missing from --preserve-env (args: $_args_line)" ;;
  esac
  unset _args_line
  # A positional target survives too (same empty-"$@" mechanism).
  : > "$SUDO_STUB_LOG"
  OLD_PATH="$PATH"
  PATH="$sudo_stub_dir:$PATH"
  run "$VALID"
  PATH="$OLD_PATH"
  [ "$STATUS" -eq 0 ] || fail "positional-target sudo re-exec exited $STATUS (want 0, stderr: $ERR)"
  case "$(grep '^args:' "$SUDO_STUB_LOG")" in
    *" $VALID") echo "ok: positional target reaches the sudo re-exec" ;;
    *) fail "positional target missing from the sudo re-exec (stub log: $(cat "$SUDO_STUB_LOG"))" ;;
  esac
  # --sudo --dry-run is a true no-op (#1313): it must never invoke sudo
  # at all -- the old code re-executed with DRY_RUN reset to 0, a real
  # writing run as root despite the no-op message.
  : > "$SUDO_STUB_LOG"
  OLD_PATH="$PATH"
  PATH="$sudo_stub_dir:$PATH"
  run --sudo --dry-run
  PATH="$OLD_PATH"
  [ "$STATUS" -eq 0 ] || fail "--sudo --dry-run exited $STATUS (want 0, stderr: $ERR)"
  [ ! -s "$SUDO_STUB_LOG" ] && echo "ok: --sudo --dry-run never invokes sudo" || fail "--sudo --dry-run invoked sudo (stub log: $(cat "$SUDO_STUB_LOG"))"
  unset _tunable _args_line
  unset SUDO_STUB_LOG
else
  echo "skip: --only-tmpdir re-exec test needs a non-root runner"
fi
# ─── Depth-1 + --follow rejected; discovery failure is loud (#1276) ──
# clean.sh was the one discovery wrapper #1268 left behind: it accepted
# --no-recursive --follow (and --depth 1 --follow), forwarded the pair to
# git-discover-repos, which rejects it at exit 2 -- and then discarded
# discover's stderr, warned generically, and completed the sweep on an
# empty discovery set at exit 0. Both spellings, in either order, must
# now exit 2 at parse time naming the pair. A discovery failure for any
# other reason (here: a nonexistent --path, which discover exits 1 on)
# must surface discover's stderr and exit non-zero instead. The
# controls -- --no-recursive alone discovering normally, and
# --depth 2 --follow parsing -- are unchanged.
for pair in "--no-recursive --follow" "--follow --no-recursive" "--depth 1 --follow" "--follow --depth 1"; do
  # shellcheck disable=SC2086
  run --dry-run --path "$VALID" $pair
  [ "$STATUS" -eq 2 ] || fail "depth-1/follow pair '$pair' exited $STATUS (want 2)"
  case "$ERR" in
    *"clean.sh: --no-recursive conflicts with --follow"*) echo "ok: pair '$pair' rejected as a conflict" ;;
    *) fail "pair '$pair' was not named as a conflict on stderr (got: $ERR)" ;;
  esac
done
run --dry-run --path "$TMP_ROOT/no-such-dir"
[ "$STATUS" -ne 0 ] || fail "discovery failure (nonexistent --path) exited 0 (want non-zero)"
case "$ERR" in
  *"git-discover-repos failed with exit 1"*"not a directory"*) echo "ok: discovery failure surfaced discover stderr and exited $STATUS" ;;
  *) fail "discovery failure did not surface discover stderr (got: $ERR)" ;;
esac
FIXTURE_REPO="$TMP_ROOT/disc/repo1"
mkdir -p "$FIXTURE_REPO/.git"
run --dry-run --path "$FIXTURE_REPO" --no-recursive
[ "$STATUS" -eq 0 ] || fail "--no-recursive control exited $STATUS (stderr: $ERR)"
case "$OUT" in
  *"1 repos, 0 worktrees"*) echo "ok: --no-recursive control reports 1 repo" ;;
  *) fail "--no-recursive control output changed (got: $OUT)" ;;
esac
run --path "$VALID" --depth 2 --follow --only-unknown-scratch
[ "$STATUS" -eq 0 ] || fail "--depth 2 --follow control exited $STATUS (stderr: $ERR)"
echo "ok: --depth 2 --follow still accepted"

# ─── Shared conformance probe matrix (#1146, design #1145) ─────────
# The matrix rows for clean.sh, driven through lib/arg-probe.sh (the
# same helper every discovery suite uses): unknown, missing/flag-shaped
# (also pinned per-option above), repeat, both conflict orders, extra
# positional, and bad numbers -- abc, 0, oversized -- for both numeric
# options. 08 is probed as accepted decimal 8 (rule 6, #881).
probe_rejected "unknown option: --bogus" --bogus
probe_rejected "clean.sh: --depth requires a value" --depth
probe_rejected "clean.sh: --docker-age requires a value" --docker-age --dry-run
probe_rejected "clean.sh: --depth may be given only once" --dry-run --path "$VALID" --depth 1 --depth 2
probe_rejected "clean.sh: --system and --no-system may not be combined" --dry-run --system --no-system
probe_rejected "clean.sh: --system and --no-system may not be combined" --dry-run --no-system --system
probe_rejected "clean.sh: --follow and --no-follow may not be combined" --dry-run --path "$VALID" --follow --no-follow
probe_rejected "clean.sh: --follow and --no-follow may not be combined" --dry-run --path "$VALID" --no-follow --follow
# Recursive pair + --depth judged at parse time (#1609), mirrored from
# git-discover-repos: any two of the three depth spellings exit 2 in
# both orders; same-side repeats stay accepted.
probe_rejected "clean.sh: --recursive and --no-recursive may not be combined" --dry-run --path "$VALID" --recursive --no-recursive
probe_rejected "clean.sh: --recursive and --no-recursive may not be combined" --dry-run --path "$VALID" --no-walk --walk
probe_rejected "clean.sh: --depth and --recursive may not be combined" --dry-run --path "$VALID" --depth 3 --walk
probe_rejected "clean.sh: --depth and --recursive may not be combined" --dry-run --path "$VALID" --recursive --depth 3
probe_rejected "clean.sh: --depth and --no-recursive may not be combined" --dry-run --path "$VALID" --depth 3 --no-recursive
probe_rejected "clean.sh: --depth and --no-recursive may not be combined" --dry-run --path "$VALID" --no-walk --depth 3
probe_accepted --dry-run --path "$VALID" --recursive --walk --only-unknown-scratch
probe_accepted --dry-run --path "$VALID" --no-recursive --no-walk --only-unknown-scratch
probe_rejected "unexpected argument: $OTHER" --dry-run "$VALID" "$OTHER"
probe_rejected "clean.sh: empty positional argument (target must not be empty)" --dry-run ""
for bad in abc 0 2147483648 99999999999999999999999999; do
  probe_rejected "clean.sh: --depth must be a positive integer" --dry-run --path "$VALID" --depth "$bad"
  probe_rejected "clean.sh: --docker-age must be a positive integer" --dry-run --path "$VALID" --docker-age "$bad"
done
probe_accepted --path "$VALID" --depth 08 --docker-age 08 --only-unknown-scratch

# Mode-effectiveness rows (#1723, design #1722), driven through the
# shared probes: the arg_used accumulator records class flags in
# either order, the arg_refuse_in_mode judge names every offending
# flag, and it fires only under --system (the --no-system control
# with the same class flags is accepted).
probe_mode_refused "clean.sh: --system conflicts with repository-scoped flags: --depth" --dry-run --system --depth 3
probe_mode_refused "clean.sh: --system conflicts with repository-scoped flags: --depth" --dry-run --depth 3 --system
probe_mode_refused "clean.sh: --system conflicts with repository-scoped flags: --quick --expire-reflog" --dry-run --system --quick --expire-reflog
# --no-recursive/--no-walk: the one repo-scoped pair the judge never saw
# (#1763) - the arm set DEPTH_LIMIT but never recorded arg_used, so
# --system silently dropped them. Both spellings, both orders, refuse
# naming the canonical --no-recursive (spotlight precedent).
probe_mode_refused "clean.sh: --system conflicts with repository-scoped flags: --no-recursive" --dry-run --system --no-recursive
probe_mode_refused "clean.sh: --system conflicts with repository-scoped flags: --no-recursive" --dry-run --no-recursive --system
probe_mode_refused "clean.sh: --system conflicts with repository-scoped flags: --no-recursive" --dry-run --system --no-walk
probe_mode_refused "clean.sh: --system conflicts with repository-scoped flags: --no-recursive" --dry-run --no-walk --system
probe_mode_accepted --dry-run --no-system --path "$VALID" --depth 3 --only-unknown-scratch

# ─── Shared operation-outcome conformance matrix (#1339) ───────────────
outcome_probe_matrix



# ─── brew_cleanup runs cleanup exactly once, and warns on failure (#1422) ───
# brew_cleanup used to run `brew cleanup --prune=all` twice: once warned,
# then again with --quiet, stderr discarded and failure swallowed
# (2>/dev/null || true), so a broken second run was invisible and every
# clean paid for the sweep twice. Pin the contract with a stub brew:
# extract the real brew_cleanup from clean.sh at test time, point
# real_brew at the stub, and count `cleanup` invocations.
BC_DIR="$TMP_ROOT/brew-cleanup"
mkdir -p "$BC_DIR"
export BREW_STUB_LOG="$BC_DIR/invocations.log"
export BREW_STUB_FAIL=0
# The stub's shebang names this bash by path, like the other stubs in this
# file: the nix build sandbox has no /usr/bin/env (#978), so an env shebang
# makes the stub unexecutable there and brew_cleanup runs it 0 times.
{ printf '#!%s\n' "$(command -v bash)"; cat <<'STUB'
echo "$*" >> "$BREW_STUB_LOG"
[ "${BREW_STUB_FAIL:-0}" = "1" ] && exit 1
exit 0
STUB
} > "$BC_DIR/brew"
chmod +x "$BC_DIR/brew"
sed -n '/^brew_cleanup() {/,/^}/p' "$SCRIPT" > "$BC_DIR/brew_cleanup.sh"
[ -s "$BC_DIR/brew_cleanup.sh" ] || fail "could not extract brew_cleanup from clean.sh"
# shellcheck disable=SC1091
. "$BC_DIR/brew_cleanup.sh"
real_brew() { printf '%s' "$BC_DIR/brew"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
info() { :; }
: > "$BREW_STUB_LOG"
BC_ERR="$(brew_cleanup 2>&1 >/dev/null)"
BC_CALLS="$(grep -c '^cleanup ' "$BREW_STUB_LOG")"
if [ "$BC_CALLS" -eq 1 ] && [ -z "$BC_ERR" ]; then
  echo "ok: brew_cleanup runs brew cleanup exactly once"
else
  [ "$BC_CALLS" -eq 1 ] || fail "brew_cleanup ran brew cleanup $BC_CALLS times (want exactly 1)"
  [ -z "$BC_ERR" ] || fail "successful brew_cleanup warned unexpectedly: $BC_ERR"
fi
BREW_STUB_FAIL=1
: > "$BREW_STUB_LOG"
BC_ERR="$(brew_cleanup 2>&1 >/dev/null)"
BC_CALLS="$(grep -c '^cleanup ' "$BREW_STUB_LOG")"
[ "$BC_CALLS" -eq 1 ] || fail "failing brew_cleanup ran brew cleanup $BC_CALLS times (want exactly 1)"
case "$BC_ERR" in
  *"brew cleanup failed"*) echo "ok: brew_cleanup failure surfaces a warning" ;;
  *) fail "brew_cleanup failure was swallowed (stderr: $BC_ERR)" ;;
esac
BREW_STUB_FAIL=0

# ─── #1465: the warn/info color gate follows its output stream ─────────────
# warn writes to stderr while info writes to stdout. Keep their gates
# independent so a terminal on one stream cannot leak escapes to a log on
# the other; NO_COLOR disables both.
GATE_DIR="$(mktemp -d)"
sed -n '/^# Gate each color by the stream/,/^set_output_colors$/p' "$SCRIPT" > "$GATE_DIR/gate.sh"
[ -s "$GATE_DIR/gate.sh" ] || fail "could not extract the output color gates from clean.sh"
grep -q 'NO_COLOR' "$GATE_DIR/gate.sh" || fail "clean.sh color gate does not consult NO_COLOR"
grep -Fq '&& -t 2' "$GATE_DIR/gate.sh" || fail "warn color gate does not test stderr"
grep -Fq '&& -t 1' "$GATE_DIR/gate.sh" || fail "info color gate does not test stdout"
gate_colors() (
  # shellcheck disable=SC1091
  . "$GATE_DIR/gate.sh" > /dev/null
  printf '%s%s%s%s' "$C_WARN" "$C_WARN_OFF" "$C_INFO" "$C_INFO_OFF"
)
[ -z "$(gate_colors 2>/dev/null)" ] || fail "color gate: piped streams still set warn/info colors"
[ -z "$(NO_COLOR=1 gate_colors 2>/dev/null)" ] || fail "color gate: NO_COLOR=1 still sets warn/info colors"
rm -rf "$GATE_DIR"

# ─── #1610: mark_dir's symlinked-marker guard (#1586) ──────────────────
# PR #1602 added the -L guard to mark_dir but no test: neither this suite
# nor full-clean.test.sh ever exercised mark_dir, so the guard could be
# dropped or reordered below the [ -e ] check and every suite would stay
# green. Extract the real mark_dir (the brew_cleanup pattern above) plus
# the real spotlight_mark it delegates to, and drive it with poisoned
# markers. Oracle: per-directory filesystem state after the call --
# clean.sh's own warning line, no write at the symlink target, the
# marker still a symlink, MARKED not incremented -- plus a clean sibling
# in the same run still marked. Mutation check (verified when written):
# deleting the -L guard makes the live case silent (the [ -e ] shortcut
# counts it as already present) and degrades the dangling case to
# spotlight_mark's differently-worded warning, so both fail below.
MD_DIR="$TMP_ROOT/mark-dir"
mkdir -p "$MD_DIR/outside"
sed -n '/^mark_dir() {/,/^}/p' "$SCRIPT" > "$MD_DIR/mark_dir.sh"
[ -s "$MD_DIR/mark_dir.sh" ] || fail "could not extract mark_dir from clean.sh"
grep -q 'cannot write.*(symlink; not followed)' "$MD_DIR/mark_dir.sh" \
  || fail "extracted mark_dir has no symlinked-marker guard to test"
sed -n '/^spotlight_mark() {/,/^}/p' "$SELF_DIR/lib/common.sh" > "$MD_DIR/spotlight_mark.sh"
[ -s "$MD_DIR/spotlight_mark.sh" ] || fail "could not extract spotlight_mark from lib/common.sh"
SPOTLIGHT_MARKER=".metadata_never_index"
DRY_RUN=0
CALLER_USER=""
MARKED=0
# shellcheck disable=SC1091
. "$MD_DIR/spotlight_mark.sh"
# shellcheck disable=SC1091
. "$MD_DIR/mark_dir.sh"

# Live symlink: marker points at an existing file outside the directory.
MD_LIVE="$MD_DIR/live"
mkdir -p "$MD_LIVE"
printf 'outside\n' > "$MD_DIR/outside/live-target"
ln -s "$MD_DIR/outside/live-target" "$MD_LIVE/$SPOTLIGHT_MARKER"
mark_dir "$MD_LIVE" 2> "$MD_DIR/live.err"
case "$(cat "$MD_DIR/live.err")" in
  *"  warning: cannot write $MD_LIVE/$SPOTLIGHT_MARKER (symlink; not followed)"*)
    echo "ok: mark_dir warns with its own line on a live symlinked marker" ;;
  *) fail "mark_dir live symlinked marker: wrong stderr (got: $(cat "$MD_DIR/live.err"))" ;;
esac
[ -L "$MD_LIVE/$SPOTLIGHT_MARKER" ] || fail "mark_dir live case: marker is no longer a symlink"
[ "$(cat "$MD_DIR/outside/live-target")" = "outside" ] \
  || fail "mark_dir live case: symlink target was modified"

# Dangling symlink: marker points at a path that does not exist, in a
# writable directory -- a followed write would create it.
MD_DANGLING="$MD_DIR/dangling"
mkdir -p "$MD_DANGLING"
ln -s "$MD_DIR/outside/dangling-target" "$MD_DANGLING/$SPOTLIGHT_MARKER"
mark_dir "$MD_DANGLING" 2> "$MD_DIR/dangling.err"
case "$(cat "$MD_DIR/dangling.err")" in
  *"  warning: cannot write $MD_DANGLING/$SPOTLIGHT_MARKER (symlink; not followed)"*)
    echo "ok: mark_dir warns with its own line on a dangling symlinked marker" ;;
  *) fail "mark_dir dangling symlinked marker: wrong stderr (got: $(cat "$MD_DIR/dangling.err"))" ;;
esac
[ -L "$MD_DANGLING/$SPOTLIGHT_MARKER" ] || fail "mark_dir dangling case: marker is no longer a symlink"
[ ! -e "$MD_DIR/outside/dangling-target" ] \
  || fail "mark_dir dangling case: a file was created at the symlink target"

# Clean sibling in the same run: still marked, and it is the ONLY one of
# the three that increments MARKED.
MD_CLEAN="$MD_DIR/clean"
mkdir -p "$MD_CLEAN"
mark_dir "$MD_CLEAN" 2> "$MD_DIR/clean.err"
[ -f "$MD_CLEAN/$SPOTLIGHT_MARKER" ] && [ ! -L "$MD_CLEAN/$SPOTLIGHT_MARKER" ] \
  || fail "mark_dir clean sibling: marker was not created as a regular file"
[ "$MARKED" -eq 1 ] || fail "mark_dir marked $MARKED directories (want exactly 1: the clean sibling)"
[ -s "$MD_DIR/clean.err" ] && fail "mark_dir clean sibling warned unexpectedly: $(cat "$MD_DIR/clean.err")"
echo "ok: mark_dir skips both symlinked markers and marks the clean sibling"

# ─── #1853: failed freshness scan must fail closed ─────────────────────
# Drive the real sweep with a failing find stub. Neither fresh nor stale
# matching entries may be offered to del when the scan is incomplete.
SS_DIR="$TMP_ROOT/short-scratch"
mkdir -p "$SS_DIR/base" "$SS_DIR/bin" "$SS_DIR/bin-idle"
touch "$SS_DIR/base/openchamber-fresh-fixture"
touch -t 200001010000 "$SS_DIR/base/openchamber-stale-fixture"
{ sed -n '/^dir_has_open_handles() {/,/^}/p' "$SCRIPT"
  sed -n '/^sweep_short_lived_scratch() {/,/^}/p' "$SCRIPT"; } > "$SS_DIR/sweep.sh"
[ -s "$SS_DIR/sweep.sh" ] || fail "could not extract sweep_short_lived_scratch"
grep -q 'dir_has_open_handles' "$SS_DIR/sweep.sh" \
  || fail "could not extract dir_has_open_handles from clean.sh (#1803)"
cat > "$SS_DIR/bin/find" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$SS_DIR/bin-idle/lsof" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$SS_DIR/bin/find" "$SS_DIR/bin-idle/lsof"
SHORT_SCRATCH_GLOBS=('openchamber-*')
SHORT_SCRATCH_STALE_HOURS=8
CALLER_USER_HOME="$SS_DIR"
_ss_total_removed=0
del() { printf '%s\n' "$1" >> "$SS_DIR/deleted"; }
warn() { printf '%s\n' "$*" >&2; }
info() { :; }
short_scratch_is_kept() { return 1; }
# shellcheck disable=SC1091
. "$SS_DIR/sweep.sh"
SS_OLD_PATH="$PATH"
TMPDIR="$SS_DIR"
PATH="$SS_DIR/bin:$PATH"
export TMPDIR PATH
set +e
sweep_short_lived_scratch "$SS_DIR/base" 2> "$SS_DIR/failure.err"
SS_RC=$?
set -e
 [ "$SS_RC" -eq 0 ] || fail "failed freshness scan returned $SS_RC"
PATH="$SS_OLD_PATH"
export PATH
[ ! -s "$SS_DIR/deleted" ] || fail "failed freshness scan offered entries to del: $(cat "$SS_DIR/deleted")"
grep -q 'freshness scan failed; skipping this base' "$SS_DIR/failure.err" \
  || fail "failed freshness scan did not warn and skip the base"

# Successful scan still deletes stale matching entries but keeps fresh ones.
# The real sweep now uses indexed arrays and string comparisons, the Bash 3.2
# semantics this fixture pins: one fresh name must not mask the stale name.
# The #2035 open-handle guard runs before del, so drive it with a working
# lsof that reports no holder (bin-idle), under the same set +e capture as
# the failed-scan call above: the guard's nonzero return is data, not an
# error, and this section runs under set -e.
rm -f "$SS_DIR/deleted"
PATH="$SS_DIR/bin-idle:$SS_OLD_PATH"
export PATH
set +e
sweep_short_lived_scratch "$SS_DIR/base"
SS_RC=$?
set -e
PATH="$SS_OLD_PATH"
export PATH
[ "$SS_RC" -eq 0 ] || fail "successful freshness scan returned $SS_RC"
grep -Fxq "$SS_DIR/base/openchamber-stale-fixture" "$SS_DIR/deleted" \
  || fail "successful freshness scan did not offer stale entry to del"
if grep -Fxq "$SS_DIR/base/openchamber-fresh-fixture" "$SS_DIR/deleted"; then
  fail "successful freshness scan offered fresh entry to del"
fi
echo "ok: short-lived scratch skips deletion on failed freshness scan and preserves successful-scan behavior"
rm -rf "$SS_DIR"

# ─── #1859: failed flake GC-root freshness scan preserves both paths ──
# Drive the extracted sweep with a find stub that fails only the
# freshness scan (-mtime): neither the GC-root link nor the result path
# may be offered to del, and the failure must warn. Controls with the
# real find: a stale project's pair is still released, an active
# project's pair is still preserved.
GC_DIR="$TMP_ROOT/gc-roots"
mkdir -p "$GC_DIR/roots" "$GC_DIR/bin" "$GC_DIR/stale-proj" "$GC_DIR/active-proj"
printf 'result\n' > "$GC_DIR/stale-proj/result"
printf 'result\n' > "$GC_DIR/active-proj/result"
printf 'recent\n' > "$GC_DIR/active-proj/source.txt"
touch -t 200001010000 "$GC_DIR/stale-proj/result"
ln -s "$GC_DIR/stale-proj/result" "$GC_DIR/roots/stale-link"
ln -s "$GC_DIR/active-proj/result" "$GC_DIR/roots/active-link"
sed -n '/^sweep_stale_flake_gc_roots() {/,/^}/p' "$SCRIPT" > "$GC_DIR/sweep.sh"
[ -s "$GC_DIR/sweep.sh" ] || fail "could not extract sweep_stale_flake_gc_roots"
REAL_FIND="$(command -v find)"
export REAL_FIND
cat > "$GC_DIR/bin/find" <<'STUB'
#!/bin/sh
case " $* " in
  *" -mtime "*) exit 1 ;;
  *) exec "$REAL_FIND" "$@" ;;
esac
STUB
chmod +x "$GC_DIR/bin/find"
CACHE_STALE_DAYS=3
del() { for _a in "$@"; do printf '%s\n' "$_a" >> "$GC_DIR/deleted"; done; }
warn() { printf '%s\n' "$*" >&2; }
info() { :; }
# shellcheck disable=SC1091
. "$GC_DIR/sweep.sh"
GC_OLD_PATH="$PATH"
PATH="$GC_DIR/bin:$PATH"
export PATH
GC_RC=0
sweep_stale_flake_gc_roots "$GC_DIR/roots" 2> "$GC_DIR/failure.err" || GC_RC=$?
PATH="$GC_OLD_PATH"
export PATH
[ "$GC_RC" -eq 0 ] || fail "failed GC-root freshness scan returned $GC_RC"
[ ! -s "$GC_DIR/deleted" ] || fail "failed freshness scan offered GC root/result to del: $(cat "$GC_DIR/deleted")"
grep -q 'freshness scan failed' "$GC_DIR/failure.err" \
  || fail "failed GC-root freshness scan did not warn"
rm -f "$GC_DIR/deleted"
sweep_stale_flake_gc_roots "$GC_DIR/roots"
grep -Fxq "$GC_DIR/roots/stale-link" "$GC_DIR/deleted" \
  || fail "successful scan did not offer stale GC-root link to del"
grep -Fxq "$GC_DIR/stale-proj/result" "$GC_DIR/deleted" \
  || fail "successful scan did not offer stale result path to del"
if grep -Fxq "$GC_DIR/roots/active-link" "$GC_DIR/deleted"; then
  fail "successful scan offered active GC-root link to del"
fi
if grep -Fxq "$GC_DIR/active-proj/result" "$GC_DIR/deleted"; then
  fail "successful scan offered active result path to del"
fi
echo "ok: flake GC-root sweep preserves both paths on failed freshness scan; stale released and active preserved on success"
rm -rf "$GC_DIR"

# ─── Bash 3.2 compatibility: no associative-array cache (#1829) ─────
# clean.sh's supported entrypoints (./clean.sh via its env-bash shebang,
# just clean) can resolve to the Bash 3.2 macOS ships at /bin/bash, and
# declare -A needs Bash 4+. The path-keyed IDLE_CACHE is parallel indexed
# arrays now. Pin both halves: no Bash-4-only constructs in the script,
# and the path-keyed cache decisions still happen in a real dry-run walk
# (idle git repo judged by its repo path; non-repo artifact judged by
# its parent path — the cache's two key sites).
if grep -nE '(local|declare)[[:space:]]+-[^[:space:]]*A|mapfile|readarray' "$SCRIPT" > /dev/null; then
  fail "clean.sh uses a Bash-4-only construct: $(grep -nE '(local|declare)[[:space:]]+-[^[:space:]]*A|mapfile|readarray' "$SCRIPT" | head -1)"
else
  echo "ok: clean.sh has no Bash-4-only constructs (#1829)"
fi
CACHE_ROOT="$TMP_ROOT/cache-fixture"
mkdir -p "$CACHE_ROOT/idle-repo/.venv"
echo stale > "$CACHE_ROOT/idle-repo/.venv/stale.txt"
printf '.venv\n' > "$CACHE_ROOT/idle-repo/.gitignore"
git -C "$CACHE_ROOT/idle-repo" init -q
git -C "$CACHE_ROOT/idle-repo" add .gitignore
GIT_AUTHOR_NAME=clean-test GIT_AUTHOR_EMAIL=clean@test GIT_COMMITTER_NAME=clean-test GIT_COMMITTER_EMAIL=clean@test git -C "$CACHE_ROOT/idle-repo" commit -qm fixture
find "$CACHE_ROOT" -exec touch -t 202501010000 {} +
# Direct capture, not the run helper: this section runs under set -e
# (toggled by an earlier section), and a full walk's exit code carries
# environment noise (user/sudo probes) that is not what is pinned here.
CACHE_OUT="$(TMPDIR="$TMP_ROOT" bash "$SCRIPT" --no-system --dry-run --path "$CACHE_ROOT" 2>/dev/null || true)"
case "$CACHE_OUT" in
  *"would delete: $CACHE_ROOT/idle-repo/.venv"*) echo "ok: idle-repo .venv judged through the path-keyed cache" ;;
  *) fail "idle-repo .venv not offered for deletion in dry-run" ;;
esac
unset CACHE_OUT CACHE_ROOT
# --- tidy: failed nested-worktree discovery skips purge/archive (#1863) ---
# tidy_classify_and_place protects nested worktrees before purging or
# archiving a scratch directory. Its .git inventory used to run through
# process substitution, so a failed find looked exactly like an empty
# inventory and the purge proceeded. Drive the REAL function extracted
# from clean.sh with stubbed helpers and a stubbed find: on discovery
# failure no destructive helper may run; successful scans keep their
# existing behavior (empty inventory -> normal leaf; kept worktree ->
# leave the whole directory alone).
TC_DIR="$TMP_ROOT/tidy-classify"
mkdir -p "$TC_DIR/subject/wt" "$TC_DIR/bucket"
awk '/^tidy_classify_and_place\(\) \{/,/^\}/' "$SCRIPT" > "$TC_DIR/fn.sh"
grep -q 'tidy_classify_and_place' "$TC_DIR/fn.sh" || fail "could not extract tidy_classify_and_place from clean.sh"

tc_run() { # tc_run <mode: fail|empty|kept> <calls-file>
  (
    # shellcheck disable=SC2034 # consumed by the sourced tidy_classify_and_place
    DRY_RUN=0; OPENCODE_WORKTREE_STALE_DAYS=30; CALLER_USER_HOME="$HOME"
    TC_CALLS="$2"; : > "$TC_CALLS"
    warn() { echo "warn: $*" >> "$TC_CALLS"; }
    tidy_dir_has_recent_file() { return 1; }
    opencode_entry_is_idle() { return 1; }
    tidy_purge_postgres_dirs() { echo purge_pg >> "$TC_CALLS"; }
    tidy_purge_large_entries() { echo purge_large >> "$TC_CALLS"; }
    tidy_dir_to_bucket() { echo archive >> "$TC_CALLS"; }
    del() { echo "del $*" >> "$TC_CALLS"; }
    case "$1" in
      fail)  find() { return 1; } ;;
      empty) find() { return 0; } ;;
      kept)  find() { printf '%s\n' "$TC_DIR/subject/wt/.git"; } ;;
    esac
    . "$TC_DIR/fn.sh"
    tidy_classify_and_place "$TC_DIR/subject" "$TC_DIR/bucket"
  )
}

tc_run fail "$TC_DIR/calls-fail"
grep -q 'nested-worktree discovery failed' "$TC_DIR/calls-fail"   || fail "failed nested-worktree discovery did not warn (#1863)"
if grep -Eq '^(purge_pg|purge_large|archive|del )' "$TC_DIR/calls-fail"; then
  fail "failed nested-worktree discovery still ran destructive helpers: $(cat "$TC_DIR/calls-fail")"
else
  echo "ok: failed nested-worktree discovery skips purge/archive (#1863)"
fi

tc_run empty "$TC_DIR/calls-empty"
grep -q '^purge_pg$' "$TC_DIR/calls-empty" && grep -q '^purge_large$' "$TC_DIR/calls-empty" && grep -q '^archive$' "$TC_DIR/calls-empty"   && echo "ok: successful empty inventory still purges/archives as a normal leaf"   || fail "successful empty inventory changed behavior: $(cat "$TC_DIR/calls-empty")"

tc_run kept "$TC_DIR/calls-kept"
if grep -Eq '^(purge_pg|purge_large|archive|del )' "$TC_DIR/calls-kept"; then
  fail "kept nested worktree no longer protects its directory: $(cat "$TC_DIR/calls-kept")"
else
  echo "ok: kept nested worktree still protects its whole directory"
fi
# --- tidy: failed freshness scan skips purge/archive (#1857) ---
# Exercise the real freshness helper and classifier. A failing find stub
# must be distinguishable from a successful empty scan, even when the
# fixture contains a fresh file. Successful controls pin both the fresh
# protect path and the stale plain-leaf purge/archive path.
TF_DIR="$TMP_ROOT/tidy-freshness"
mkdir -p "$TF_DIR/bin" "$TF_DIR/subject/fail" "$TF_DIR/subject/recent" "$TF_DIR/subject/stale"
touch "$TF_DIR/subject/fail/fresh.txt" "$TF_DIR/subject/recent/fresh.txt"
touch -t 200001010000 "$TF_DIR/subject/stale/old.txt"
{ sed -n '/^tidy_dir_has_recent_file() {/,/^}/p' "$SCRIPT"
  sed -n '/^tidy_classify_and_place() {/,/^}/p' "$SCRIPT"; } > "$TF_DIR/fn.sh"
[ -s "$TF_DIR/fn.sh" ] || fail "could not extract tidy freshness/classifier functions"
cat > "$TF_DIR/bin/find" <<'STUB'
#!/bin/sh
for arg do
  if [ "$arg" = "-mtime" ]; then
    [ "$TF_MODE" != fail ] || exit 1
    break
  fi
done
exec "$TF_REAL_FIND" "$@"
STUB
chmod +x "$TF_DIR/bin/find"
TF_REAL_FIND="$(command -v find)"
export TF_REAL_FIND
tf_run() { # tf_run <mode: fail|recent|stale>
  (
    DRY_RUN=0; OPENCODE_WORKTREE_STALE_DAYS=30; OPENCODE_TIDY_PROTECT_DAYS=1
    CALLER_USER_HOME="$HOME"; TF_MODE="$1"; export TF_MODE; TF_CALLS="$TF_DIR/calls-$1"
    : > "$TF_CALLS"
    warn() { echo "warn: $*" >> "$TF_CALLS"; }
    tidy_purge_postgres_dirs() { echo purge_pg >> "$TF_CALLS"; }
    tidy_purge_large_entries() { echo purge_large >> "$TF_CALLS"; }
    tidy_dir_to_bucket() { echo archive >> "$TF_CALLS"; }
    del() { echo "del $*" >> "$TF_CALLS"; }
    . "$TF_DIR/fn.sh"
    PATH="$TF_DIR/bin:$PATH"
    tidy_classify_and_place "$TF_DIR/subject/$1" "$TF_DIR/bucket"
  )
}
tf_run fail
grep -q 'freshness scan failed' "$TF_DIR/calls-fail" \
  || fail "failed freshness scan did not warn (#1857)"
if grep -Eq '^(purge_pg|purge_large|archive|del )' "$TF_DIR/calls-fail"; then
  fail "failed freshness scan still purged/archived: $(cat "$TF_DIR/calls-fail")"
else
  echo "ok: failed freshness scan skips purge/archive (#1857)"
fi
tf_run recent
if grep -Eq '^(purge_pg|purge_large|archive|del )' "$TF_DIR/calls-recent"; then
  fail "successful recent-file scan no longer protects its directory: $(cat "$TF_DIR/calls-recent")"
else
  echo "ok: successful recent-file scan still protects its directory"
fi
tf_run stale
grep -q '^purge_large$' "$TF_DIR/calls-stale" && grep -q '^archive$' "$TF_DIR/calls-stale" \
  || fail "successful empty freshness scan no longer purges/archives: $(cat "$TF_DIR/calls-stale")"
echo "ok: successful empty freshness scan preserves normal tidy behavior"
# ─── #1861: artifact_is_prunable fails closed on a failed freshness scan ──
# The freshness find's exit status used to be discarded, so a failed scan
# read as "no fresh files" and the caller deleted the artifact. Extract
# the real function (the mark_dir pattern above) and drive it with a
# failing find stub (the #1853 pattern). Oracle: return status + the
# warning line + a caller-shaped del recorder that must stay empty.
# Mutation check: with the status check removed, the failed-scan case
# below returns prunable and the recorder fires, so the section fails.
AP_DIR="$TMP_ROOT/artifact-prunable"
mkdir -p "$AP_DIR/bin-fail" "$AP_DIR/bin-ok" "$AP_DIR/bin-open" \
  "$AP_DIR/stale/node_modules" "$AP_DIR/fresh/node_modules"
touch -t 200001010000 "$AP_DIR/stale/node_modules/pkg.js"
touch "$AP_DIR/fresh/node_modules/pkg.js"
{ sed -n '/^dir_has_open_handles() {/,/^}/p' "$SCRIPT"
  sed -n '/^artifact_is_prunable() {/,/^}/p' "$SCRIPT"; } > "$AP_DIR/fn.sh"
[ -s "$AP_DIR/fn.sh" ] || fail "could not extract artifact_is_prunable from clean.sh"
grep -q 'dir_has_open_handles' "$AP_DIR/fn.sh" \
  || fail "could not extract dir_has_open_handles from clean.sh (#1803)"
grep -q 'freshness scan failed' "$AP_DIR/fn.sh" \
  || fail "extracted artifact_is_prunable has no fail-closed scan guard to test"
SPOTLIGHT_MARKER=".metadata_never_index"
# shellcheck disable=SC2034  # consumed by the extracted function below
ACTIVE_ARTIFACT_STALE_HOURS=8
# shellcheck disable=SC1091
. "$AP_DIR/fn.sh"
cat > "$AP_DIR/bin-fail/find" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$AP_DIR/bin-fail/lsof" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$AP_DIR/bin-ok/lsof" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$AP_DIR/bin-open/lsof" <<'STUB'
#!/bin/sh
echo "node 4242 user 9r DIR 1,5 0 0 /fixture"
exit 0
STUB
chmod +x "$AP_DIR/bin-fail/find" "$AP_DIR/bin-fail/lsof" \
  "$AP_DIR/bin-ok/lsof" "$AP_DIR/bin-open/lsof"
AP_OLD_PATH="$PATH"
del_and_stub() { printf '%s\n' "$1" >> "$AP_DIR/deleted"; }

# Failed scan: not prunable, warns, and the caller-shaped guard (the
# clean.sh:1583 shape) never offers the artifact to del_and_stub.
PATH="$AP_DIR/bin-fail:$AP_OLD_PATH"
if artifact_is_prunable "$AP_DIR/stale/node_modules" 2> "$AP_DIR/fail.err"; then
  del_and_stub "$AP_DIR/stale/node_modules"
fi
[ ! -e "$AP_DIR/deleted" ] \
  || fail "failed freshness scan offered a stale artifact to del_and_stub"
grep -q 'freshness scan failed' "$AP_DIR/fail.err" \
  || fail "failed freshness scan did not warn (got: $(cat "$AP_DIR/fail.err"))"
echo "ok: failed freshness scan keeps the artifact and warns"

# Controls with the real find: a stale artifact is prunable, a fresh one
# is not (and does not warn), and an open file keeps a stale artifact.
PATH="$AP_DIR/bin-ok:$AP_OLD_PATH"
if artifact_is_prunable "$AP_DIR/stale/node_modules" 2> "$AP_DIR/stale.err"; then
  echo "ok: successful scan still judges a stale artifact prunable"
else
  fail "successful scan no longer judges a stale artifact prunable"
fi
if artifact_is_prunable "$AP_DIR/fresh/node_modules" 2> "$AP_DIR/fresh.err"; then
  fail "successful scan judged a fresh artifact prunable"
else
  echo "ok: successful scan still keeps a fresh artifact"
fi
[ -s "$AP_DIR/fresh.err" ] \
  && fail "fresh-artifact control warned unexpectedly: $(cat "$AP_DIR/fresh.err")"
PATH="$AP_DIR/bin-open:$AP_OLD_PATH"
if artifact_is_prunable "$AP_DIR/stale/node_modules" 2>/dev/null; then
  fail "open-file control judged a stale artifact prunable despite lsof output"
else
  echo "ok: lsof output still keeps a stale artifact"
fi
PATH="$AP_OLD_PATH"
rm -rf "$AP_DIR"

# ─── #1803: postgres sweep fails closed when lsof cannot run ──────
# sweep_ad_hoc_postgres_dirs read empty lsof output as "not held", so
# an lsof that never ran (missing from PATH, or erroring) silently
# disabled the in-use guard and stale-looking LIVE postgres data dirs
# were deleted. Extract the real sweep + its dir_has_open_handles
# helper and drive four PATH-stub scenarios against a stale PG_VERSION
# fixture. Oracle: the del recorder + the "cannot verify" note --
# missing/erroring lsof keeps, a holder keeps, a working lsof with no
# holder still removes. Mutation check: reverting the sweep to the raw
# lsof test makes the missing/erroring cases record a deletion.
PG_DIR="$TMP_ROOT/lsof-fail-closed"
mkdir -p "$PG_DIR/base/pgdata" "$PG_DIR/bin-missing" \
  "$PG_DIR/bin-error" "$PG_DIR/bin-held" "$PG_DIR/bin-idle"
touch "$PG_DIR/base/pgdata/PG_VERSION"
touch -t 200001010000 "$PG_DIR/base/pgdata/PG_VERSION"
{ sed -n '/^dir_has_open_handles() {/,/^}/p' "$SCRIPT"
  sed -n '/^sweep_ad_hoc_postgres_dirs() {/,/^}/p' "$SCRIPT"; } > "$PG_DIR/fn.sh"
grep -q 'sweep_ad_hoc_postgres_dirs' "$PG_DIR/fn.sh" \
  || fail "could not extract sweep_ad_hoc_postgres_dirs from clean.sh (#1803)"
grep -q 'dir_has_open_handles' "$PG_DIR/fn.sh" \
  || fail "extracted sweep has no dir_has_open_handles helper to test (#1803)"
# bin-missing gets the real find/dirname and NO lsof at all.
ln -s "$(command -v find)" "$PG_DIR/bin-missing/find"
ln -s "$(command -v dirname)" "$PG_DIR/bin-missing/dirname"
cat > "$PG_DIR/bin-error/lsof" <<'STUB'
#!/bin/sh
exit 2
STUB
cat > "$PG_DIR/bin-held/lsof" <<'STUB'
#!/bin/sh
echo "postgres 4242 user 9r DIR 1,5 0 0 /fixture"
exit 0
STUB
cat > "$PG_DIR/bin-idle/lsof" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$PG_DIR/bin-error/lsof" "$PG_DIR/bin-held/lsof" "$PG_DIR/bin-idle/lsof"

pg_run() { # pg_run <PATH> -- runs the extracted sweep in a subshell
  (
    # shellcheck disable=SC2034 # consumed by the sourced sweep
    DRY_RUN=0; PG_SCRATCH_STALE_HOURS=8
    # shellcheck disable=SC2034 # consumed by the sourced sweep
    SPOTLIGHT_MARKER=".metadata_never_index"; CALLER_USER_HOME="$HOME"
    PATH="$1"
    del() { printf '%s\n' "$1" >> "$PG_DIR/deleted"; }
    . "$PG_DIR/fn.sh"
    sweep_ad_hoc_postgres_dirs "$PG_DIR/base"
  )
}

: > "$PG_DIR/deleted"
OUT="$(pg_run "$PG_DIR/bin-missing" 2>&1 || true)"
[ ! -s "$PG_DIR/deleted" ] \
  || fail "lsof missing: postgres sweep deleted a data dir it could not verify (#1803)"
case "$OUT" in
  *"keeping (cannot verify open handles; lsof unavailable)"*) echo "ok: lsof missing keeps the postgres data dir with a cannot-verify note" ;;
  *) fail "lsof missing: no cannot-verify note (got: $OUT)" ;;
esac

: > "$PG_DIR/deleted"
OUT="$(pg_run "$PG_DIR/bin-error:$PATH" 2>&1 || true)"
[ ! -s "$PG_DIR/deleted" ] \
  || fail "lsof erroring: postgres sweep deleted a data dir it could not verify (#1803)"
case "$OUT" in
  *"keeping (cannot verify open handles; lsof unavailable)"*) echo "ok: lsof erroring keeps the postgres data dir with a cannot-verify note" ;;
  *) fail "lsof erroring: no cannot-verify note (got: $OUT)" ;;
esac

: > "$PG_DIR/deleted"
OUT="$(pg_run "$PG_DIR/bin-held:$PATH" 2>&1 || true)"
[ ! -s "$PG_DIR/deleted" ] \
  || fail "lsof reporting a holder: postgres sweep deleted a held data dir (#1803)"
echo "ok: lsof reporting a holder keeps the postgres data dir"

: > "$PG_DIR/deleted"
OUT="$(pg_run "$PG_DIR/bin-idle:$PATH" 2>&1 || true)"
grep -q "^$PG_DIR/base/pgdata$" "$PG_DIR/deleted" \
  || fail "working lsof with no holder: postgres sweep no longer removes an idle data dir (deleted: $(cat "$PG_DIR/deleted"); out: $OUT)"
echo "ok: working lsof with no holder still removes the idle postgres data dir"
rm -rf "$PG_DIR"

# ─── #2035: short-lived scratch sweep fails closed when lsof cannot run ──
# sweep_short_lived_scratch deleted stale known-tool scratch (and stale
# uv locks) with no open-handle check at all, unlike its sibling sweeps
# (#1803): a tool holding an old-mtime directory open lost it anyway, and
# an lsof that never ran could not keep anything. Extract the real sweep
# + its dir_has_open_handles helper and drive four PATH-stub scenarios
# against a stale glob-matched fixture dir and a stale uv lock. Oracle:
# the del recorder + the "cannot verify" note -- missing/erroring lsof
# keeps, a holder keeps, a working lsof with no holder still removes.
# Mutation check: reverting the sweep to the unguarded del makes the
# missing/erroring cases record a deletion.
SG_DIR="$TMP_ROOT/short-scratch-fail-closed"
mkdir -p "$SG_DIR/base/opencode-stale-fixture" "$SG_DIR/bin-missing" \
  "$SG_DIR/bin-error" "$SG_DIR/bin-held" "$SG_DIR/bin-idle"
touch -t 200001010000 "$SG_DIR/base/opencode-stale-fixture"
touch "$SG_DIR/base/uv-fixture.lock"
touch -t 200001010000 "$SG_DIR/base/uv-fixture.lock"
{ sed -n '/^dir_has_open_handles() {/,/^}/p' "$SCRIPT"
  sed -n '/^sweep_short_lived_scratch() {/,/^}/p' "$SCRIPT"; } > "$SG_DIR/fn.sh"
grep -q 'sweep_short_lived_scratch' "$SG_DIR/fn.sh" \
  || fail "could not extract sweep_short_lived_scratch from clean.sh (#2035)"
grep -q 'dir_has_open_handles' "$SG_DIR/fn.sh" \
  || fail "extracted sweep has no dir_has_open_handles helper to test (#2035)"
# bin-missing gets the real find/mktemp/rm and NO lsof at all.
ln -s "$(command -v find)" "$SG_DIR/bin-missing/find"
ln -s "$(command -v mktemp)" "$SG_DIR/bin-missing/mktemp"
ln -s "$(command -v rm)" "$SG_DIR/bin-missing/rm"
cat > "$SG_DIR/bin-error/lsof" <<'STUB'
#!/bin/sh
exit 2
STUB
cat > "$SG_DIR/bin-held/lsof" <<'STUB'
#!/bin/sh
echo "opencode 4242 user 9r DIR 1,5 0 0 /fixture"
exit 0
STUB
cat > "$SG_DIR/bin-idle/lsof" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$SG_DIR/bin-error/lsof" "$SG_DIR/bin-held/lsof" "$SG_DIR/bin-idle/lsof"

sg_run() { # sg_run <PATH> -- runs the extracted sweep in a subshell
  (
    # shellcheck disable=SC2034 # consumed by the sourced sweep
    SHORT_SCRATCH_STALE_HOURS=8; CALLER_USER_HOME="$HOME"
    # shellcheck disable=SC2034 # consumed by the sourced sweep
    SHORT_SCRATCH_GLOBS=('opencode-*'); _ss_total_removed=0
    TMPDIR="$SG_DIR"
    PATH="$1"
    del() { printf '%s\n' "$1" >> "$SG_DIR/deleted"; }
    warn() { printf '%s\n' "$*" >&2; }
    info() { :; }
    short_scratch_is_kept() { return 1; }
    . "$SG_DIR/fn.sh"
    sweep_short_lived_scratch "$SG_DIR/base"
  )
}

: > "$SG_DIR/deleted"
OUT="$(sg_run "$SG_DIR/bin-missing" 2>&1 || true)"
[ ! -s "$SG_DIR/deleted" ] \
  || fail "lsof missing: short-lived scratch sweep deleted an entry it could not verify (#2035)"
case "$OUT" in
  *"keeping (cannot verify open handles; lsof unavailable)"*) echo "ok: lsof missing keeps the short-lived scratch entry with a cannot-verify note" ;;
  *) fail "lsof missing: no cannot-verify note (got: $OUT)" ;;
esac

: > "$SG_DIR/deleted"
OUT="$(sg_run "$SG_DIR/bin-error:$PATH" 2>&1 || true)"
[ ! -s "$SG_DIR/deleted" ] \
  || fail "lsof erroring: short-lived scratch sweep deleted an entry it could not verify (#2035)"
case "$OUT" in
  *"keeping (cannot verify open handles; lsof unavailable)"*) echo "ok: lsof erroring keeps the short-lived scratch entry with a cannot-verify note" ;;
  *) fail "lsof erroring: no cannot-verify note (got: $OUT)" ;;
esac

: > "$SG_DIR/deleted"
OUT="$(sg_run "$SG_DIR/bin-held:$PATH" 2>&1 || true)"
[ ! -s "$SG_DIR/deleted" ] \
  || fail "lsof reporting a holder: short-lived scratch sweep deleted a held entry (#2035)"
echo "ok: lsof reporting a holder keeps the short-lived scratch entry"

: > "$SG_DIR/deleted"
OUT="$(sg_run "$SG_DIR/bin-idle:$PATH" 2>&1 || true)"
grep -q "^$SG_DIR/base/opencode-stale-fixture$" "$SG_DIR/deleted" \
  || fail "working lsof with no holder: short-lived scratch sweep no longer removes a stale entry (deleted: $(cat "$SG_DIR/deleted"); out: $OUT)"
grep -q "^$SG_DIR/base/uv-fixture.lock$" "$SG_DIR/deleted" \
  || fail "working lsof with no holder: short-lived scratch sweep no longer removes a stale uv lock (deleted: $(cat "$SG_DIR/deleted"); out: $OUT)"
echo "ok: working lsof with no holder still removes the stale short-lived scratch entry and uv lock"
rm -rf "$SG_DIR"

# ─── #1904: del() must not skip dangling symlinks ─────────────────────
# del() gated every deletion on [ -e "$p" ], which is false for a
# dangling symlink, so stale dangling links in caches/logs/Trash were
# silently skipped: no "would delete" line under --dry-run, no deletion
# or warning on a real run. Extract the real del() and drive it.
# Oracle: per-path filesystem state plus the dry-run line -- a dangling
# link is reported under DRY_RUN=1 and removed under DRY_RUN=0; a live
# symlink is removed without touching its target; a missing path is
# still skipped silently. (This section runs under set -e -- see the
# #1853 section -- so every real-run del call is guarded with
# || fail: an unguarded non-zero return would kill the suite silently
# instead of failing a case.) Mutation check (verified when written):
# dropping the [ -L ] half of the gate makes the dangling cases fail
# (no dry-run line, link survives) while the controls stay green.
DEL_DIR="$TMP_ROOT/del-dangling"
mkdir -p "$DEL_DIR"
sed -n '/^del() {/,/^}/p' "$SCRIPT" > "$DEL_DIR/del.sh"
[ -s "$DEL_DIR/del.sh" ] || fail "could not extract del from clean.sh"
grep -q '\[ -L "\$p" \]' "$DEL_DIR/del.sh" \
  || fail "extracted del has no symlink (-L) gate to test"
warn() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC1091
. "$DEL_DIR/del.sh"

# Dangling symlink under dry-run: reported, not removed.
ln -s "$DEL_DIR/no-such-target" "$DEL_DIR/dangling-link"
DEL_DRY_OUT="$(DRY_RUN=1 del "$DEL_DIR/dangling-link")"
case "$DEL_DRY_OUT" in
  *"would delete: $DEL_DIR/dangling-link"*) echo "ok: del reports a dangling symlink under dry-run" ;;
  *) fail "del dry-run did not report the dangling symlink (got: $DEL_DRY_OUT)" ;;
esac
[ -L "$DEL_DIR/dangling-link" ] || fail "del dry-run removed the dangling symlink"

# Dangling symlink on a real run: the link itself is removed.
DRY_RUN=0 del "$DEL_DIR/dangling-link" || fail "del returned non-zero on a dangling symlink"
[ ! -L "$DEL_DIR/dangling-link" ] && [ ! -e "$DEL_DIR/dangling-link" ] \
  || fail "del left the dangling symlink in place on a real run"
echo "ok: del removes a dangling symlink on a real run"

# Live symlink control: link removed, target untouched.
printf 'target\n' > "$DEL_DIR/live-target"
ln -s "$DEL_DIR/live-target" "$DEL_DIR/live-link"
DRY_RUN=0 del "$DEL_DIR/live-link" || fail "del returned non-zero on a live symlink"
[ ! -L "$DEL_DIR/live-link" ] || fail "del left a live symlink in place"
[ "$(cat "$DEL_DIR/live-target")" = "target" ] \
  || fail "del followed a live symlink and modified its target"

# Missing path control: skipped silently, no output, no failure.
DEL_MISSING_OUT="$(DRY_RUN=0 del "$DEL_DIR/never-existed" 2>&1 || true)"
[ -z "$DEL_MISSING_OUT" ] || fail "del on a missing path produced output: $DEL_MISSING_OUT"
echo "ok: del handles dangling/live symlinks and still skips missing paths silently"
rm -rf "$DEL_DIR"

# ─── #1915: sweep [ -e ] pre-filters must not skip dangling symlinks ──
# Six sweep loops gated entries on [ -e "$entry" ] before del() or the
# tidy judges ever ran; -e is false for a dangling symlink, so stale
# dangling links were silently skipped by every sweep even after #1904
# fixed del() itself. Oracle: per-loop filesystem state / dry-run lines
# for a dangling link judged by the REAL extracted functions, plus a
# static pin that each of the six loop bodies carries the -L gate.
# Mutation check: dropping the [ -L ] half from any loop makes its
# behavioral case fail (entry never reaches the judges) and the static
# pin fail for that loop. tidy_purge_large_entries has no behavioral
# case: a dangling link's du is 0, so its size gate judges it out on
# size either way -- the static pin is its coverage.
SW_DIR="$TMP_ROOT/sweep-dangling"
mkdir -p "$SW_DIR"
for fn in sweep_unknown_large_scratch sweep_short_lived_scratch \
  clean_opencode_scratch_dir clean_opencode_root_scratch \
  tidy_purge_large_entries tidy_opencode_loose_files; do
  awk "/^$fn\\(\\) \\{/,/^\\}/" "$SCRIPT" > "$SW_DIR/$fn.sh"
  grep -q "$fn" "$SW_DIR/$fn.sh" || fail "could not extract $fn from clean.sh (#1915)"
  if grep -q '\[ -L "\$entry" \]' "$SW_DIR/$fn.sh"; then
    echo "ok: $fn gates on existence-or-symlink (#1915)"
  else
    fail "$fn has no [ -L ] gate -- dangling symlinks are pre-filtered (#1915)"
  fi
done
sed -n '/^del() {/,/^}/p' "$SCRIPT" > "$SW_DIR/del.sh"
awk '/^dir_has_open_handles\(\) \{/,/^\}/' "$SCRIPT" > "$SW_DIR/dir_has_open_handles.sh"
grep -q 'dir_has_open_handles' "$SW_DIR/dir_has_open_handles.sh" \
  || fail "could not extract dir_has_open_handles from clean.sh (#1803)"
mkdir -p "$SW_DIR/no-holder-bin"
printf '#!/bin/sh\nexit 1\n' > "$SW_DIR/no-holder-bin/lsof"
chmod +x "$SW_DIR/no-holder-bin/lsof"

# sweep_short_lived_scratch: a stale dangling link matching a scratch
# glob is removed on a real run; a fresh one is kept by the age gate.
(
  # shellcheck disable=SC2034 # consumed by the sourced sweep_short_lived_scratch
  DRY_RUN=0; CALLER_USER_HOME="$HOME"; SHORT_SCRATCH_STALE_HOURS=8
  TMPDIR="$SW_DIR"  # an earlier section exports a TMPDIR it later removes
  # shellcheck disable=SC2034 # consumed by the sourced sweep_short_lived_scratch
  SHORT_SCRATCH_GLOBS=('opencode-*'); _ss_total_removed=0
  warn() { printf '%s\n' "$*" >&2; }
  info() { printf '%s\n' "$*"; }
  short_scratch_is_kept() { return 1; }
  PATH="$SW_DIR/no-holder-bin:$PATH"
  . "$SW_DIR/del.sh"
  . "$SW_DIR/dir_has_open_handles.sh"
  . "$SW_DIR/sweep_short_lived_scratch.sh"
  mkdir -p "$SW_DIR/short"
  ln -s "$SW_DIR/no-such-target" "$SW_DIR/short/opencode-stale123"
  ln -s "$SW_DIR/no-such-target" "$SW_DIR/short/opencode-fresh123"
  touch -h -t 202501010000 "$SW_DIR/short/opencode-stale123"
  sweep_short_lived_scratch "$SW_DIR/short"
  [ ! -L "$SW_DIR/short/opencode-stale123" ] \
    || { echo "SWEEP_FAIL stale dangling link survived sweep_short_lived_scratch" >&2; exit 1; }
  [ -L "$SW_DIR/short/opencode-fresh123" ] \
    || { echo "SWEEP_FAIL fresh dangling link was removed by sweep_short_lived_scratch" >&2; exit 1; }
) && echo "ok: sweep_short_lived_scratch removes a stale dangling link, keeps a fresh one" \
  || fail "sweep_short_lived_scratch dangling-symlink case (#1915)"

# clean_opencode_scratch_dir + clean_opencode_root_scratch: with the
# idle judge stubbed idle, a dangling link is reported under dry-run.
(
  DRY_RUN=1; CALLER_USER_HOME="$HOME"
  # shellcheck disable=SC2034 # consumed by the sourced clean_opencode_root_scratch
  OPENCODE_ROOT_PROTECTED=(.DS_Store auth.json tmp)
  warn() { printf '%s\n' "$*" >&2; }
  info() { printf '%s\n' "$*"; }
  opencode_entry_is_idle() { return 0; }
  . "$SW_DIR/del.sh"
  . "$SW_DIR/clean_opencode_scratch_dir.sh"
  . "$SW_DIR/clean_opencode_root_scratch.sh"
  mkdir -p "$SW_DIR/scratch" "$SW_DIR/root"
  ln -s "$SW_DIR/no-such-target" "$SW_DIR/scratch/stale-link"
  ln -s "$SW_DIR/no-such-target" "$SW_DIR/root/stray-link"
  OUT1="$(clean_opencode_scratch_dir "$SW_DIR/scratch" 7 "tmp/opencode")"
  case "$OUT1" in
    *"would remove: $SW_DIR/scratch/stale-link"*) : ;;
    *) echo "SWEEP_FAIL clean_opencode_scratch_dir dry-run missed dangling link: $OUT1" >&2; exit 1 ;;
  esac
  OUT2="$(clean_opencode_root_scratch "$SW_DIR/root" 7)"
  case "$OUT2" in
    *"would remove: $SW_DIR/root/stray-link"*) : ;;
    *) echo "SWEEP_FAIL clean_opencode_root_scratch dry-run missed dangling link: $OUT2" >&2; exit 1 ;;
  esac
) && echo "ok: opencode scratch sweeps report a dangling link under dry-run" \
  || fail "opencode scratch sweeps dangling-symlink case (#1915)"

# sweep_unknown_large_scratch: with the size floor at 0, a stale
# dangling link is judged and reported instead of pre-filtered.
(
  # shellcheck disable=SC2034 # consumed by the sourced sweep_unknown_large_scratch
  DRY_RUN=1; CALLER_USER_HOME="$HOME"; PRUNE_UNKNOWN_SCRATCH=1
  # shellcheck disable=SC2034 # consumed by the sourced sweep_unknown_large_scratch
  UNKNOWN_SCRATCH_STALE_DAYS=7; UNKNOWN_SCRATCH_MIN_MB=0
  # shellcheck disable=SC2034 # consumed by the sourced sweep_unknown_large_scratch
  UNKNOWN_SCRATCH_HITS=()
  warn() { printf '%s\n' "$*" >&2; }
  info() { printf '%s\n' "$*"; }
  unknown_scratch_is_known() { return 1; }
  stat_birth_time() { echo unknown; }
  stat_mtime_time() { echo unknown; }
  PATH="$SW_DIR/no-holder-bin:$PATH"
  . "$SW_DIR/del.sh"
  . "$SW_DIR/dir_has_open_handles.sh"
  . "$SW_DIR/sweep_unknown_large_scratch.sh"
  mkdir -p "$SW_DIR/unknown"
  ln -s "$SW_DIR/no-such-target" "$SW_DIR/unknown/mystery-link"
  touch -h -t 202501010000 "$SW_DIR/unknown/mystery-link"
  OUT3="$(sweep_unknown_large_scratch "$SW_DIR/unknown")"
  case "$OUT3" in
    *"would remove (unknown, 0 MB"*) : ;;
    *) echo "SWEEP_FAIL sweep_unknown_large_scratch missed dangling link: $OUT3" >&2; exit 1 ;;
  esac
) && echo "ok: sweep_unknown_large_scratch judges a dangling link instead of pre-filtering it" \
  || fail "sweep_unknown_large_scratch dangling-symlink case (#1915)"

awk '/^tidy_file_to_bucket\(\) \{/,/^\}/' "$SCRIPT" > "$SW_DIR/tidy_file_to_bucket.sh"
grep -q 'tidy_file_to_bucket' "$SW_DIR/tidy_file_to_bucket.sh" \
  || fail "could not extract tidy_file_to_bucket from clean.sh (#1915)"
# tidy_opencode_loose_files: a dangling link reaches the new symlink
# branch and is filed away like a loose file (the link itself moves).
(
  # shellcheck disable=SC2034 # consumed by the sourced tidy functions
  DRY_RUN=0; CALLER_USER_HOME="$HOME"; SPOTLIGHT_MARKER=".metadata_never_index"
  # shellcheck disable=SC2034 # consumed by the sourced tidy_file_to_bucket
  TIDY_MOVE_FAILURES=0
  warn() { printf '%s\n' "$*" >&2; }
  info() { printf '%s\n' "$*"; }
  tidy_classify_and_place() { echo "SWEEP_FAIL tidy classified a dangling link as a dir" >&2; exit 1; }
  . "$SW_DIR/tidy_file_to_bucket.sh" 2>/dev/null || true
  . "$SW_DIR/tidy_opencode_loose_files.sh"
  mkdir -p "$SW_DIR/loose" "$SW_DIR/bucket"
  ln -s "$SW_DIR/no-such-target" "$SW_DIR/loose/dangling-note"
  tidy_opencode_loose_files "$SW_DIR/loose" "$SW_DIR/bucket"
  [ ! -L "$SW_DIR/loose/dangling-note" ] \
    || { echo "SWEEP_FAIL dangling link left in place by tidy_opencode_loose_files" >&2; exit 1; }
  [ -n "$(find "$SW_DIR/bucket" -type l -name dangling-note 2>/dev/null)" ] \
    || { echo "SWEEP_FAIL dangling link not filed into the tidy bucket" >&2; exit 1; }
) && echo "ok: tidy_opencode_loose_files files a dangling link away" \
  || fail "tidy_opencode_loose_files dangling-symlink case (#1915)"
rm -rf "$SW_DIR"


# ─── brew_cask_drift_check fails closed when brew list --cask fails (#1918) ───
# The orphan/dead-cask drift checks used to enumerate via process/command
# substitution with 2>/dev/null, so a present-but-failing brew produced
# empty results and the run claimed "no drift" at exit 0. Pin the
# fail-closed contract with a stub brew, extracting the real
# brew_cask_drift_check from clean.sh at test time (the brew_cleanup
# extraction pattern, #1422 -- sourced and driven in this shell, not a
# subshell: this suite's EXIT trap fires in subshells and would delete
# TMP_ROOT mid-section): a failing enumeration warns naming the step,
# surfaces brew's stderr, and records BREW_DRIFT_FAILURES (the run's
# final gate turns that into a non-zero exit); a successful enumeration
# is the control -- no failure recorded, orphans reported.
DRIFT_DIR="$TMP_ROOT/brew-drift"
mkdir -p "$DRIFT_DIR"
cat > "$DRIFT_DIR/casks.nix" <<'NIX'
_: {
  homebrew.casks = [
    "docker-desktop"
  ];
}
NIX
printf '#!%s\n' "$(command -v bash)" > "$DRIFT_DIR/brew"
cat >> "$DRIFT_DIR/brew" <<'STUB'
if [ "$1 $2" = "list --cask" ]; then
  if [ "${DRIFT_BREW_FAIL:-0}" = "1" ]; then
    echo "Error: brew exploded" >&2
    exit 1
  fi
  printf 'docker-desktop\norphan-cask\n'
  exit 0
fi
exit 0
STUB
chmod +x "$DRIFT_DIR/brew"
sed -n '/^brew_cask_drift_check() {/,/^}/p' "$SCRIPT" > "$DRIFT_DIR/drift.sh"
[ -s "$DRIFT_DIR/drift.sh" ] || fail "could not extract brew_cask_drift_check from clean.sh (#1918)"
DRIFT_SELF_DIR_SAVE="$SELF_DIR"
SELF_DIR="$DRIFT_DIR"
BREW_DRIFT_FAILURES=0
warn() { printf '%s\n' "$*" >&2; }
real_brew() { printf '%s' "$DRIFT_DIR/brew"; }
as_user() { "$@"; }
. "$DRIFT_DIR/drift.sh"
# Section-local TMPDIR (the line-1324 precedent): an earlier section
# exports a TMPDIR it later removes, and brew_cask_drift_check's mktemp
# would fail against the removed dir -- under this suite's set -e that
# failing assignment would exit the whole suite mid-section.
DRIFT_TMPDIR_SAVE="${TMPDIR:-}"
TMPDIR="$DRIFT_DIR"
export TMPDIR
# Direct calls with file capture (not $(...)): the failure counter is a
# shell variable, and a command substitution would run the function in
# a subshell and lose the increment.
DRIFT_BREW_FAIL=1 brew_cask_drift_check >"$DRIFT_DIR/out-fail" 2>"$DRIFT_DIR/err-fail"
DRIFT_FAILURES_FAIL=$BREW_DRIFT_FAILURES
DRIFT_ERR_FAIL="$(cat "$DRIFT_DIR/err-fail")"
BREW_DRIFT_FAILURES=0
DRIFT_BREW_FAIL=0 brew_cask_drift_check >"$DRIFT_DIR/out-ok" 2>"$DRIFT_DIR/err-ok"
DRIFT_FAILURES_OK=$BREW_DRIFT_FAILURES
DRIFT_OUT_OK="$(cat "$DRIFT_DIR/out-ok")"
DRIFT_ERR_OK="$(cat "$DRIFT_DIR/err-ok")"
SELF_DIR="$DRIFT_SELF_DIR_SAVE"
if [ -n "$DRIFT_TMPDIR_SAVE" ]; then TMPDIR="$DRIFT_TMPDIR_SAVE"; else unset TMPDIR; fi
export TMPDIR
[ "$DRIFT_FAILURES_FAIL" -eq 1 ] \
  || fail "failing brew list --cask recorded $DRIFT_FAILURES_FAIL drift failure(s) (want 1) (#1918)"
case "$DRIFT_ERR_FAIL" in
  *"brew list --cask failed"*) echo "ok: drift check names the failed step on enumeration failure" ;;
  *) fail "drift check did not name the failed step (got: $DRIFT_ERR_FAIL) (#1918)" ;;
esac
case "$DRIFT_ERR_FAIL" in
  *"brew exploded"*) echo "ok: drift check surfaces brew's own stderr" ;;
  *) fail "drift check swallowed brew's stderr (got: $DRIFT_ERR_FAIL) (#1918)" ;;
esac
case "$DRIFT_ERR_FAIL" in
  *"not in casks.nix"*) fail "drift check reported orphans from a failed enumeration (#1918)" ;;
  *) echo "ok: drift check reports no orphans from a failed enumeration" ;;
esac
[ "$DRIFT_FAILURES_OK" -eq 0 ] \
  || fail "successful brew list --cask recorded a drift failure (#1918)"
case "$DRIFT_OUT_OK" in
  *"orphan-cask"*) echo "ok: drift check control reports the orphan cask" ;;
  *) fail "drift check control did not report orphan-cask (got: $DRIFT_OUT_OK / $DRIFT_ERR_OK) (#1918)" ;;
esac

# ─── mas_app_drift_check fails closed when mas list fails (#2018) ───
# Same fail-open shape as #1918, adjacent code: the App Store drift check
# ran `as_user mas list 2>/dev/null` in a process substitution, so a
# present-but-failing mas looked exactly like a successful empty listing.
# Pin the fail-closed contract with a stub mas, extracting the real
# mas_app_drift_check from clean.sh at test time (the #1918 extraction
# pattern, sourced and driven in this shell): a failing enumeration warns
# naming the step, surfaces mas's stderr, and records MAS_DRIFT_FAILURES;
# successful-with-orphan reports the orphan with no failure recorded;
# successful-empty records no failure and reports no orphans.
MAS_DIR="$TMP_ROOT/mas-drift"
mkdir -p "$MAS_DIR/bin"
cat > "$MAS_DIR/masApps.nix" <<'NIX'
_: {
  masApps = {
    "Known App" = 111;
  };
}
NIX
printf '#!%s\n' "$(command -v bash)" > "$MAS_DIR/bin/mas"
cat >> "$MAS_DIR/bin/mas" <<'STUB'
if [ "$1" = "list" ]; then
  case "${MAS_STUB_MODE:-empty}" in
    fail)
      echo "Error: mas exploded" >&2
      exit 1
      ;;
    orphan)
      printf '111 Known App (1.0)\n222 Orphan App (2.0)\n'
      exit 0
      ;;
    *)
      printf '111 Known App (1.0)\n'
      exit 0
      ;;
  esac
fi
exit 0
STUB
chmod +x "$MAS_DIR/bin/mas"
sed -n '/^mas_app_drift_check() {/,/^}/p' "$SCRIPT" > "$MAS_DIR/drift.sh"
[ -s "$MAS_DIR/drift.sh" ] || fail "could not extract mas_app_drift_check from clean.sh (#2018)"
MAS_SELF_DIR_SAVE="$SELF_DIR"
SELF_DIR="$MAS_DIR"
MAS_DRIFT_FAILURES=0
warn() { printf '%s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
as_user() { "$@"; }
. "$MAS_DIR/drift.sh"
MAS_TMPDIR_SAVE="${TMPDIR:-}"
TMPDIR="$MAS_DIR"
export TMPDIR
MAS_PATH_SAVE="$PATH"
PATH="$MAS_DIR/bin:$PATH"
MAS_STUB_MODE=fail mas_app_drift_check >"$MAS_DIR/out-fail" 2>"$MAS_DIR/err-fail"
MAS_FAILURES_FAIL=$MAS_DRIFT_FAILURES
MAS_ERR_FAIL="$(cat "$MAS_DIR/err-fail")"
MAS_DRIFT_FAILURES=0
MAS_STUB_MODE=orphan mas_app_drift_check >"$MAS_DIR/out-orphan" 2>"$MAS_DIR/err-orphan"
MAS_FAILURES_ORPHAN=$MAS_DRIFT_FAILURES
MAS_OUT_ORPHAN="$(cat "$MAS_DIR/out-orphan")"
MAS_ERR_ORPHAN="$(cat "$MAS_DIR/err-orphan")"
MAS_DRIFT_FAILURES=0
MAS_STUB_MODE=empty mas_app_drift_check >"$MAS_DIR/out-empty" 2>"$MAS_DIR/err-empty"
MAS_FAILURES_EMPTY=$MAS_DRIFT_FAILURES
MAS_ERR_EMPTY="$(cat "$MAS_DIR/err-empty")"
PATH="$MAS_PATH_SAVE"
SELF_DIR="$MAS_SELF_DIR_SAVE"
if [ -n "$MAS_TMPDIR_SAVE" ]; then TMPDIR="$MAS_TMPDIR_SAVE"; else unset TMPDIR; fi
export TMPDIR
[ "$MAS_FAILURES_FAIL" -eq 1 ] \
  || fail "failing mas list recorded $MAS_FAILURES_FAIL drift failure(s) (want 1) (#2018)"
case "$MAS_ERR_FAIL" in
  *"mas list failed"*) echo "ok: mas drift check names the failed step on enumeration failure" ;;
  *) fail "mas drift check did not name the failed step (got: $MAS_ERR_FAIL) (#2018)" ;;
esac
case "$MAS_ERR_FAIL" in
  *"mas exploded"*) echo "ok: mas drift check surfaces mas's own stderr" ;;
  *) fail "mas drift check swallowed mas's stderr (got: $MAS_ERR_FAIL) (#2018)" ;;
esac
case "$MAS_ERR_FAIL" in
  *"not in masApps.nix"*) fail "mas drift check reported orphans from a failed enumeration (#2018)" ;;
  *) echo "ok: mas drift check reports no orphans from a failed enumeration" ;;
esac
[ "$MAS_FAILURES_ORPHAN" -eq 0 ] \
  || fail "successful mas list recorded a drift failure (#2018)"
case "$MAS_OUT_ORPHAN" in
  *"Orphan App"*) echo "ok: mas drift check control reports the orphan app" ;;
  *) fail "mas drift check control did not report Orphan App (got: $MAS_OUT_ORPHAN / $MAS_ERR_ORPHAN) (#2018)" ;;
esac
[ "$MAS_FAILURES_EMPTY" -eq 0 ] \
  || fail "successful empty mas list recorded a drift failure (#2018)"
case "$MAS_ERR_EMPTY" in
  *"not in masApps.nix"*) fail "mas drift check reported orphans from a successful empty listing (#2018)" ;;
  *) echo "ok: mas drift check reports no orphans from a successful empty listing" ;;
esac

# --- Colima recreation requires two complete Docker listings (#1831) --------
# Run the real cleanup script in dry-run mode with a fake Colima profile and
# Docker CLI. The daemon probe succeeds; each listing can independently fail,
# so an empty wc result must never be mistaken for a verified zero.
COLIMA_TEST="$TMP_ROOT/colima-listings"
COLIMA_BIN="$COLIMA_TEST/bin"
COLIMA_HOME="$COLIMA_TEST/home"
COLIMA_APP="$COLIMA_TEST/app"
COLIMA_BASH="$(command -v bash)"
REAL_DU="$(command -v du)"
export REAL_DU
mkdir -p "$COLIMA_BIN" "$COLIMA_HOME/.colima/default" \
  "$COLIMA_HOME/.colima/_lima/_disks/colima" "$COLIMA_APP/lib"
# Keep this full-script integration fixture hermetic: omitting the Homebrew
# manifest files skips unrelated host brew/mas probes, while copying runtime
# dependencies keeps SELF_DIR's relative references valid.
cp "$SELF_DIR/clean.sh" "$SELF_DIR/git-discover-repos" "$SELF_DIR/var-folders-clean.sh" "$COLIMA_APP/"
cp "$SELF_DIR/lib/common.sh" "$SELF_DIR/lib/arg-probe.sh" "$SELF_DIR/lib/outcome-probe.sh" "$COLIMA_APP/lib/"
{
  printf '#!%s\n' "$COLIMA_BASH"
  cat <<'STUB'
if [ -n "${DOCKER_HOST:-}" ]; then
  case "$1" in
    info) exit 0 ;;
    ps)
      case "${DOCKER_PS_MODE:-empty}" in
        fail) printf 'partial-container\n'; exit 7 ;;
        silent-fail) exit 7 ;;
        nonempty) printf 'container-id\n'; exit 0 ;;
        *) exit 0 ;;
      esac
      ;;
    volume)
      case "${DOCKER_VOLUME_MODE:-empty}" in
        fail) printf 'partial-volume\n'; exit 8 ;;
        silent-fail) exit 8 ;;
        nonempty) printf 'volume-name\n'; exit 0 ;;
        *) exit 0 ;;
      esac
      ;;
  esac
fi
exit 0
STUB
} > "$COLIMA_BIN/docker"
{
  printf '#!%s\n' "$COLIMA_BASH"
  cat <<'STUB'
exit 0
STUB
} > "$COLIMA_BIN/colima"
{
  printf '#!%s\n' "$COLIMA_BASH"
  cat <<'STUB'
case "$*" in
  *"/.colima/_lima/_disks/colima"*) printf '1048577\t%s\n' "${*: -1}" ;;
  *) "$REAL_DU" "$@" ;;
esac
STUB
} > "$COLIMA_BIN/du"
chmod +x "$COLIMA_BIN/docker" "$COLIMA_BIN/colima" "$COLIMA_BIN/du"
run_colima_case() { # <ps mode> <volume mode> — sets output and status
  DOCKER_PS_MODE="$1" DOCKER_VOLUME_MODE="$2" HOME="$COLIMA_HOME" \
    PATH="$COLIMA_BIN:$PATH" bash "$COLIMA_APP/clean.sh" --system --dry-run \
      >"$COLIMA_TEST/out" 2>"$COLIMA_TEST/err"
  COLIMA_STATUS=$?
  COLIMA_OUT="$(cat "$COLIMA_TEST/out")"
  COLIMA_ERR="$(cat "$COLIMA_TEST/err")"
}
expect_colima_no_delete() {
  case "$COLIMA_OUT" in
    *"would run: as_user colima stop -p default"*|*"would run: as_user colima delete -f -p default"*)
      fail "$1 attempted the Colima deletion path (status $COLIMA_STATUS)" ;;
    *) echo "ok: $1 leaves the Colima profile intact" ;;
  esac
}
run_colima_case fail empty
expect_colima_no_delete "failed docker ps with successful empty volume listing"
case "$COLIMA_OUT$COLIMA_ERR" in
  *"docker ps"*) echo "ok: failed docker ps is diagnosed" ;;
  *) fail "failed docker ps was not diagnosed (got: $COLIMA_OUT / $COLIMA_ERR)" ;;
esac
run_colima_case silent-fail empty
expect_colima_no_delete "silent failed docker ps with successful empty volume listing"
case "$COLIMA_OUT$COLIMA_ERR" in
  *"docker ps"*) echo "ok: silent failed docker ps is diagnosed" ;;
  *) fail "silent failed docker ps was not diagnosed (got: $COLIMA_OUT / $COLIMA_ERR)" ;;
esac
run_colima_case empty fail
expect_colima_no_delete "failed docker volume ls with successful empty container listing"
case "$COLIMA_OUT$COLIMA_ERR" in
  *"docker volume ls"*) echo "ok: failed docker volume ls is diagnosed" ;;
  *) fail "failed docker volume ls was not diagnosed (got: $COLIMA_OUT / $COLIMA_ERR)" ;;
esac
run_colima_case empty silent-fail
expect_colima_no_delete "silent failed docker volume ls with successful empty container listing"
case "$COLIMA_OUT$COLIMA_ERR" in
  *"docker volume ls"*) echo "ok: silent failed docker volume ls is diagnosed" ;;
  *) fail "silent failed docker volume ls was not diagnosed (got: $COLIMA_OUT / $COLIMA_ERR)" ;;
esac
run_colima_case nonempty empty
expect_colima_no_delete "verified non-empty container listing"
run_colima_case empty nonempty
expect_colima_no_delete "verified non-empty volume listing"
run_colima_case empty empty
case "$COLIMA_OUT" in
  *"would run: as_user colima stop -p default"*"would run: as_user colima delete -f -p default"*)
    echo "ok: two verified empty listings permit Colima recreation" ;;
  *) fail "two verified empty listings did not enter recreation path (got: $COLIMA_OUT)" ;;
esac

# ─── #1902: dead-cask extraction spans multi-word app names ─────────────
# The dead-cask check extracted the installed app path from `brew info`
# with grep -oE '/Applications/[^ ]*\.app'. [^ ]* cannot span the space in
# a multi-word bundle name, so those casks extracted empty and were
# silently skipped by the MISSING-from-disk warning. Extract the real
# block from clean.sh at test time, point it at a stub brew through the
# CLEAN_APPS_DIR seam, and pin: multi-word dead flags, multi-word present
# does not, and the single-word control still flags exactly as before.
DC_DIR="$TMP_ROOT/dead-cask"
mkdir -p "$DC_DIR/apps/Present Multi.app"
# The nix build sandbox has no /usr/bin/env, so this runtime-generated stub
# must use a shebang that exists there (same failure class as the unpatched
# script copies flake.nix patches with patchShebangs). /bin/sh suffices: the
# stub only uses printf/case/exit.
cat > "$DC_DIR/brew" <<'EOF'
#!/bin/sh
if [ "$1" = list ]; then printf '%s\n' dead-multi present-multi single-word; exit 0; fi
if [ "$1" = info ]; then
  case "$3" in
    dead-multi)    printf '%s (App)\n' "$CLEAN_APPS_DIR/Dead Multi.app" ;;
    present-multi) printf '%s (App)\n' "$CLEAN_APPS_DIR/Present Multi.app" ;;
    single-word)   printf '%s (App)\n' "$CLEAN_APPS_DIR/Single.app" ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$DC_DIR/brew"
sed -n '/^  _dead=""/,/MISSING from disk/p' "$SCRIPT" > "$DC_DIR/block.sh"
[ -s "$DC_DIR/block.sh" ] || fail "could not extract the dead-cask block from clean.sh"
grep -q 'info --cask' "$DC_DIR/block.sh" || fail "extracted dead-cask block lacks the brew info extraction"
grep -q 'CLEAN_APPS_DIR:-/Applications' "$SCRIPT" || fail "dead-cask extraction lost its /Applications default"
# This section runs under set -e, and the extracted block ends in a
# `[ -n "$_dead" ] && {...}` list: an empty _dead makes it return 1, which
# under set -e would abort the whole suite with no diagnostic. Capture
# without letting that status kill the run; the case checks below still
# report a real failure (mirrors the CACHE_OUT capture above).
# Section-local TMPDIR (the #1918 precedent above): the #1853 section
# exports a TMPDIR it later removes, and the dead-cask block's mktemp
# (#2066) would fail against the removed dir -- point TMPDIR at a live
# dir for the capture, then restore it.
DC_TMPDIR_SAVE="${TMPDIR:-}"
TMPDIR="$DC_DIR"
export TMPDIR
DC_OUT="$(
  as_user() { "$@"; }
  warn() { printf 'WARN: %s\n' "$*"; }
  _b="$DC_DIR/brew"
  _cask_list="dead-multi present-multi single-word"
  export CLEAN_APPS_DIR="$DC_DIR/apps"
  . "$DC_DIR/block.sh"
  exit 0
)"
if [ -n "$DC_TMPDIR_SAVE" ]; then TMPDIR="$DC_TMPDIR_SAVE"; else unset TMPDIR; fi
export TMPDIR
case "$DC_OUT" in
  *"MISSING from disk"*) echo "ok: dead-cask block warns on missing apps" ;;
  *) fail "dead-cask block produced no MISSING warning (got: $DC_OUT)" ;;
esac
case "$DC_OUT" in
  *dead-multi*) echo "ok: multi-word dead cask is flagged" ;;
  *) fail "multi-word dead cask was not flagged (got: $DC_OUT)" ;;
esac
case "$DC_OUT" in
  *present-multi*) fail "multi-word present cask was flagged (got: $DC_OUT)" ;;
  *) echo "ok: multi-word present cask is not flagged" ;;
esac
case "$DC_OUT" in
  *single-word*) echo "ok: single-word dead cask still flagged (control)" ;;
  *) fail "single-word dead cask was not flagged (got: $DC_OUT)" ;;
esac

# ─── #2190: dead-cask extraction stops at the first .app ────────────────
# PR #1978's multi-word fix (#1902) made the extraction greedy: .* extends
# to the LAST .app on the brew info line, so a line naming a second bundle
# after the path (source and target artifacts, e.g.
# "/Applications/Present Multi.app (Present Multi.app)") extracted a
# non-path and a present cask was falsely flagged MISSING. Same extracted-
# block harness as the #1902 section; pin: with that line shape a present
# multi-word cask is NOT flagged, and a dead one still is.
DT_DIR="$TMP_ROOT/dead-cask-second-app"
mkdir -p "$DT_DIR/apps/Present Multi.app"
cat > "$DT_DIR/brew" <<'STUBEOF'
#!/bin/sh
if [ "$1" = list ]; then printf '%s\n' dead-multi present-multi; exit 0; fi
if [ "$1" = info ]; then
  case "$3" in
    dead-multi)    printf '%s (%s)\n' "$CLEAN_APPS_DIR/Dead Multi.app" "Dead Multi.app" ;;
    present-multi) printf '%s (%s)\n' "$CLEAN_APPS_DIR/Present Multi.app" "Present Multi.app" ;;
  esac
  exit 0
fi
exit 0
STUBEOF
chmod +x "$DT_DIR/brew"
sed -n '/^  _dead=""/,/MISSING from disk/p' "$SCRIPT" > "$DT_DIR/block.sh"
[ -s "$DT_DIR/block.sh" ] || fail "could not extract the dead-cask block from clean.sh (#2190)"
grep -q 'info --cask' "$DT_DIR/block.sh" || fail "extracted dead-cask block lacks the brew info extraction (#2190)"
# Same set -e / section-local TMPDIR handling as the #1902 section above.
DT_TMPDIR_SAVE="${TMPDIR:-}"
TMPDIR="$DT_DIR"
export TMPDIR
DT_OUT="$(
  as_user() { "$@"; }
  warn() { printf 'WARN: %s\n' "$*"; }
  _b="$DT_DIR/brew"
  _cask_list="dead-multi present-multi"
  export CLEAN_APPS_DIR="$DT_DIR/apps"
  . "$DT_DIR/block.sh"
  exit 0
)"
if [ -n "$DT_TMPDIR_SAVE" ]; then TMPDIR="$DT_TMPDIR_SAVE"; else unset TMPDIR; fi
export TMPDIR
case "$DT_OUT" in
  *"MISSING from disk"*) echo "ok: second-.app block warns on missing apps" ;;
  *) fail "second-.app block produced no MISSING warning (got: $DT_OUT)" ;;
esac
case "$DT_OUT" in
  *dead-multi*) echo "ok: multi-word dead cask with a second .app token is flagged" ;;
  *) fail "multi-word dead cask with a second .app token was not flagged (got: $DT_OUT)" ;;
esac
case "$DT_OUT" in
  *present-multi*) fail "present multi-word cask with a second .app token was flagged (got: $DT_OUT)" ;;
  *) echo "ok: present multi-word cask with a second .app token is not flagged" ;;
esac

# ─── #2066: dead-cask per-cask `brew info --cask` failure fails closed ──
# The dead-cask half enumerated each cask's app path with `brew info
# --cask` inside a 2>/dev/null pipeline whose status is head's, not
# brew's, so a failed per-cask query produced an empty app path, the
# [ -n "$_app" ] guard skipped the cask, and the run claimed "no dead
# casks" at exit 0. Pin the fail-closed contract with a stub brew,
# extracting the real brew_cask_drift_check from clean.sh at test time
# (the #1918 extraction pattern above -- sourced and driven in this
# shell, not a subshell: the failure counter is a shell variable, and
# this suite's EXIT trap fires in subshells): a failing per-cask query
# warns naming the cask and the step, surfaces brew's stderr, and
# records BREW_DRIFT_FAILURES; a successful query naming a missing app
# still flags that dead cask, and a successful query naming a present
# app still does not flag.
DI_DIR="$TMP_ROOT/dead-info"
mkdir -p "$DI_DIR/apps/Present App.app"
cat > "$DI_DIR/casks.nix" <<'NIX'
_: {
  homebrew.casks = [
    "dead-cask"
    "present-cask"
    "failing-cask"
  ];
}
NIX
cat > "$DI_DIR/brew" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "list --cask" ]; then printf '%s\n' dead-cask present-cask failing-cask; exit 0; fi
if [ "$1" = info ]; then
  case "$3" in
    dead-cask)    printf '%s (App)\n' "$CLEAN_APPS_DIR/Dead App.app" ;;
    present-cask) printf '%s (App)\n' "$CLEAN_APPS_DIR/Present App.app" ;;
    failing-cask) echo "Error: nonexistent cask failing-cask" >&2; exit 1 ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$DI_DIR/brew"
sed -n '/^brew_cask_drift_check() {/,/^}/p' "$SCRIPT" > "$DI_DIR/drift.sh"
[ -s "$DI_DIR/drift.sh" ] || fail "could not extract brew_cask_drift_check from clean.sh (#2066)"
grep -q 'BREW_DRIFT_FAILURES' "$DI_DIR/drift.sh" || fail "extracted drift check lacks the failure counter (#2066)"
DI_SELF_DIR_SAVE="$SELF_DIR"
SELF_DIR="$DI_DIR"
real_brew() { printf '%s' "$DI_DIR/brew"; }
BREW_DRIFT_FAILURES=0
DI_TMPDIR_SAVE="${TMPDIR:-}"
TMPDIR="$DI_DIR"
export TMPDIR
export CLEAN_APPS_DIR="$DI_DIR/apps"
brew_cask_drift_check >"$DI_DIR/out" 2>"$DI_DIR/err"
DI_FAILURES=$BREW_DRIFT_FAILURES
DI_OUT="$(cat "$DI_DIR/out")"
DI_ERR="$(cat "$DI_DIR/err")"
SELF_DIR="$DI_SELF_DIR_SAVE"
if [ -n "$DI_TMPDIR_SAVE" ]; then TMPDIR="$DI_TMPDIR_SAVE"; else unset TMPDIR; fi
export TMPDIR
unset CLEAN_APPS_DIR
[ "$DI_FAILURES" -eq 1 ] \
  || fail "failing brew info --cask recorded $DI_FAILURES drift failure(s) (want 1) (#2066)"
case "$DI_ERR" in
  *"brew info --cask failing-cask failed"*) echo "ok: dead-cask check names the cask and the failed step (#2066)" ;;
  *) fail "dead-cask check did not name the cask and step (got: $DI_ERR) (#2066)" ;;
esac
case "$DI_ERR" in
  *"nonexistent cask failing-cask"*) echo "ok: dead-cask check surfaces brew's own stderr (#2066)" ;;
  *) fail "dead-cask check swallowed brew's stderr (got: $DI_ERR) (#2066)" ;;
esac
case "$DI_ERR" in
  *"MISSING from disk"*) echo "ok: dead-cask check still warns on missing apps (#2066)" ;;
  *) fail "dead-cask check produced no MISSING warning (got: $DI_OUT / $DI_ERR) (#2066)" ;;
esac
case "$DI_OUT" in
  *dead-cask*) echo "ok: successful query naming a missing app still flags that dead cask (#2066)" ;;
  *) fail "successful query naming a missing app did not flag it (got: $DI_OUT) (#2066)" ;;
esac
case "$DI_OUT" in
  *present-cask*) fail "successful query naming a present app was flagged (got: $DI_OUT) (#2066)" ;;
  *) echo "ok: successful query naming a present app still does not flag (#2066)" ;;
esac
case "$DI_OUT" in
  *failing-cask*) fail "failed query was reported as a dead cask instead of an enumeration failure (got: $DI_OUT) (#2066)" ;;
  *) echo "ok: failed query is never reported as a dead cask (#2066)" ;;
esac



# ─── oseries checkout guard: local work is never deleted (#2040) ───
# clean.sh used to `del "$CALLER_USER_HOME/git/oseries"` unconditionally,
# so a checkout holding uncommitted changes or commits no remote has was
# destroyed by a cleanup run. The guard (git_checkout_keep_reason) must
# keep such a checkout and say why, in --dry-run too, while a clean,
# fully pushed checkout -- and a plain non-repo directory -- are still
# deleted exactly as before. Following the dead-cask precedent above,
# the real blocks are extracted from clean.sh at test time (never pasted
# copies) and driven against fixture repos; a full system-half run is
# not an option here because on a developer machine it would reach real
# docker/brew/nix tooling. The warn sink is stubbed (logging only, per
# the dead-cask precedent); del, have and the guard itself are the real
# extracted code.
export GIT_AUTHOR_NAME="clean.test" GIT_AUTHOR_EMAIL="clean.test@example.invalid"
export GIT_COMMITTER_NAME="clean.test" GIT_COMMITTER_EMAIL="clean.test@example.invalid"
OS_DIR_BASE="$TMP_ROOT/oseries-guard"
OS_HOME="$OS_DIR_BASE/home"
OS_DIR="$OS_HOME/git/oseries"
OS_REMOTE="$OS_DIR_BASE/remote.git"
mkdir -p "$OS_HOME/git"
OS_HELPERS="$OS_DIR_BASE/helpers.sh"
OS_CALL="$OS_DIR_BASE/callsite.sh"
sed -n '/^del() {/,/^}/p' "$SCRIPT" > "$OS_HELPERS"
grep '^have() {' "$SCRIPT" >> "$OS_HELPERS"
sed -n '/^git_checkout_keep_reason() {/,/^}/p' "$SCRIPT" >> "$OS_HELPERS"
sed -n '/^# The oseries checkout is a real working repo/,/^unset _oseries_reason/p' "$SCRIPT" > "$OS_CALL"
[ -s "$OS_HELPERS" ] || fail "could not extract the oseries guard helpers from clean.sh"
[ -s "$OS_CALL" ] || fail "could not extract the oseries call site from clean.sh"
grep -q 'status --porcelain' "$OS_HELPERS" || fail "extracted guard lacks the dirty check"
grep -q 'stash list' "$OS_HELPERS" || fail "extracted guard lacks the stash check"
grep -q 'rev-list' "$OS_HELPERS" || fail "extracted guard lacks the unpushed check"
grep -q 'git_checkout_keep_reason' "$OS_CALL" || fail "extracted call site does not call the guard"
grep -q 'del "$OSERIES_DIR"' "$OS_CALL" || fail "extracted call site does not delete via del"
oseries_run() { # <dry-run 0|1> — sets OUT
  OUT="$(
    HOME="$OS_HOME"
    CALLER_USER_HOME="$OS_HOME"
    DRY_RUN="$1"
    warn() { printf 'WARN: %s\n' "$*"; }
    . "$OS_HELPERS"
    . "$OS_CALL"
    exit 0
  )"
}
oseries_fresh_repo() { # one commit, pushed to the bare remote; tree clean
  rm -rf "$OS_DIR" "$OS_REMOTE"
  mkdir -p "$OS_DIR"
  git init -q --bare -b main "$OS_REMOTE" || fail "oseries fixture: bare init failed"
  git init -q -b main "$OS_DIR" || fail "oseries fixture: init failed"
  echo base > "$OS_DIR/file.txt"
  git -C "$OS_DIR" add file.txt || fail "oseries fixture: add failed"
  git -C "$OS_DIR" commit -qm base || fail "oseries fixture: commit failed"
  git -C "$OS_DIR" remote add origin "$OS_REMOTE" || fail "oseries fixture: remote add failed"
  git -C "$OS_DIR" push -q -u origin main || fail "oseries fixture: push failed"
}
# Dirty checkout (modified tracked file + untracked file): kept, reason named.
oseries_fresh_repo
echo dirty >> "$OS_DIR/file.txt"
echo scratch > "$OS_DIR/untracked.txt"
oseries_run 0
[ -d "$OS_DIR" ] && echo "ok: dirty oseries checkout is kept" || fail "dirty oseries checkout was deleted"
case "$OUT" in
  *"keeping"*"uncommitted changes"*) echo "ok: dirty keep names the reason" ;;
  *) fail "dirty keep did not name the reason (got: $OUT)" ;;
esac
# Same checkout under --dry-run: kept, and no "would delete" for it.
oseries_run 1
[ -d "$OS_DIR" ] && echo "ok: dry-run leaves the dirty checkout in place" || fail "dry-run removed the dirty checkout"
case "$OUT" in
  *"would delete"*) fail "dry-run offered to delete the dirty checkout (got: $OUT)" ;;
  *"keeping"*) echo "ok: dry-run reports the keep instead of a delete" ;;
  *) fail "dry-run neither kept nor deleted the dirty checkout (got: $OUT)" ;;
esac
# Clean tree but one commit no remote has: kept, reason named.
oseries_fresh_repo
echo more >> "$OS_DIR/file.txt"
git -C "$OS_DIR" commit -qam second || fail "oseries fixture: second commit failed"
oseries_run 0
[ -d "$OS_DIR" ] && echo "ok: unpushed oseries checkout is kept" || fail "unpushed oseries checkout was deleted"
case "$OUT" in
  *"keeping"*"not pushed to any remote"*) echo "ok: unpushed keep names the reason" ;;
  *) fail "unpushed keep did not name the reason (got: $OUT)" ;;
esac
# Clean and fully pushed: deleted exactly as before.
oseries_fresh_repo
oseries_run 0
[ ! -e "$OS_DIR" ] && echo "ok: clean pushed oseries checkout is deleted as before" || fail "clean pushed oseries checkout was kept"
case "$OUT" in
  *"keeping"*) fail "clean pushed checkout printed a keep warning (got: $OUT)" ;;
  *) echo "ok: clean pushed checkout printed no keep warning" ;;
esac
# Clean and fully pushed under --dry-run: reported, not deleted.
oseries_fresh_repo
oseries_run 1
[ -d "$OS_DIR" ] && echo "ok: dry-run leaves the clean checkout in place" || fail "dry-run removed the clean checkout"
case "$OUT" in
  *"would delete:"*"oseries"*) echo "ok: dry-run still reports the clean checkout as would-delete" ;;
  *) fail "dry-run did not report would-delete for the clean checkout (got: $OUT)" ;;
esac
# A plain directory (not a git work tree): deleted as before.
rm -rf "$OS_DIR"
mkdir -p "$OS_DIR"
echo junk > "$OS_DIR/junk.txt"
oseries_run 0
[ ! -e "$OS_DIR" ] && echo "ok: non-repo oseries directory is deleted as before" || fail "non-repo oseries directory was kept"
# ─── #2110: the stash probe fails closed like its sibling probes ───
# The rev-list probe can never see stash commits (refs/stash is neither a
# branch nor HEAD), so the stash probe is the only thing protecting
# stashed work; it used to read any empty `git stash list` output as
# "no stash" with no exit-status check, so a damaged stash ref turned
# the guard into a deletion.
oseries_run_stash_fails() { # <dry-run 0|1> — like oseries_run, but git stash list exits nonzero
  OUT="$(
    HOME="$OS_HOME"
    CALLER_USER_HOME="$OS_HOME"
    DRY_RUN="$1"
    warn() { printf 'WARN: %s\n' "$*"; }
    git() {
      _os_prev=""
      for _os_a in "$@"; do
        if [ "$_os_prev" = "stash" ] && [ "$_os_a" = "list" ]; then return 1; fi
        _os_prev="$_os_a"
      done
      command git "$@"
    }
    . "$OS_HELPERS"
    . "$OS_CALL"
    exit 0
  )"
}
# Clean tree, everything pushed, one stash entry: kept, stash reason named.
oseries_fresh_repo
echo stashed > "$OS_DIR/stash.txt"
git -C "$OS_DIR" stash push -q -u -m test-stash || fail "oseries fixture: stash push failed"
oseries_run 0
[ -d "$OS_DIR" ] && echo "ok: stashed oseries checkout is kept (#2110)" || fail "stashed oseries checkout was deleted (#2110)"
case "$OUT" in
  *"keeping"*"stash"*) echo "ok: stash keep names the reason (#2110)" ;;
  *) fail "stash keep did not name the reason (got: $OUT) (#2110)" ;;
esac
# Same, but refs/stash removed with the objects and reflog left behind
# (an interrupted drop, a partial restore): every other probe reads
# empty, yet the checkout must still be kept, not deleted.
oseries_fresh_repo
echo stashed > "$OS_DIR/stash.txt"
git -C "$OS_DIR" stash push -q -u -m test-stash || fail "oseries fixture: stash push failed"
OS_GIT_DIR="$(git -C "$OS_DIR" rev-parse --absolute-git-dir)" || fail "oseries fixture: rev-parse --absolute-git-dir failed"
rm "$OS_GIT_DIR/refs/stash" || fail "oseries fixture: could not remove refs/stash"
[ -z "$(git -C "$OS_DIR" stash list 2>/dev/null)" ] || fail "oseries fixture: stash list not empty after refs/stash removal (#2110)"
oseries_run 0
[ -d "$OS_DIR" ] && echo "ok: damaged-stash-ref oseries checkout is kept (#2110)" || fail "damaged-stash-ref oseries checkout was deleted (#2110)"
case "$OUT" in
  *"keeping"*"stash"*) echo "ok: damaged-stash-ref keep names the stash reason (#2110)" ;;
  *) fail "damaged-stash-ref keep did not name the stash reason (got: $OUT) (#2110)" ;;
esac
# git stash list forced to fail (nonzero): kept as unverifiable.
oseries_fresh_repo
oseries_run_stash_fails 0
[ -d "$OS_DIR" ] && echo "ok: unverifiable-stash oseries checkout is kept (#2110)" || fail "unverifiable-stash oseries checkout was deleted (#2110)"
case "$OUT" in
  *"keeping"*"cannot be verified"*) echo "ok: unverifiable-stash keep names the reason (#2110)" ;;
  *) fail "unverifiable-stash keep did not name the reason (got: $OUT) (#2110)" ;;
esac


[ "$failures" -eq 0 ] || { echo "$failures failure(s)" >&2; exit 1; }
echo "all clean.sh flag-shaped-value checks passed"
