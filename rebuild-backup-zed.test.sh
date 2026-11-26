#!/usr/bin/env bash
# Tests for the rebuild.sh / backup-zed.sh argument guards (#1190):
#   PR #1169 added the same no-argument guard to three scripts
#   (#1167), but full-clean.test.sh pins only the bash script. The
#   two zsh scripts' copies of the guard had no test at all, so a
#   future edit (or a zsh parsing quirk) could silently restore the
#   #1167 behaviour: --help / a typo'd flag runs the rebuild or the
#   backup and exits 0.
# This drives the REAL rebuild.sh and backup-zed.sh under zsh (their
# interpreter) in scratch dirs:
#   * rebuild.sh: git / nix are logging PATH stubs and
#     ./simple-rebuild.sh is a logging step stub beside the script.
#   * backup-zed.sh: the backup writes only inside the scratch work
#     dir from a fixture HOME, so its side effects are directly
#     observable (a copied settings.json / index.json / installed.txt
#     appears only when the script actually runs).
# It pins, for each script:
#   * --help and -h -> usage on stdout, exit 0, no side effects;
#   * any other argument -> exit 2, the argument named on stderr,
#     usage on stderr, no side effects;
#   * no argument -> the stubbed/fixture sequence runs and exits 0
#     (the control: the empty-log legs above pass only because the
#     guard stops the script, not because it cannot run).
# Stubs use #!/bin/sh: the nix build sandbox has no /usr/bin/env.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok: $desc"
  else
    fail "$desc"
  fi
}

BIN="$TMP_ROOT/bin"
HOME_DIR="$TMP_ROOT/home"
LOG="$TMP_ROOT/steps.log"
REAL_CP="$(command -v cp)"
REAL_MV="$(command -v mv)"
REAL_RM="$(command -v rm)"
export REAL_CP REAL_MV REAL_RM
mkdir -p "$BIN" "$HOME_DIR"
: > "$LOG"

# PATH stubs for rebuild.sh: log every call, exit 0.
for cmd in git nix; do
  cat > "$BIN/$cmd" <<EOF
#!/bin/sh
echo "$cmd \$*" >> "$LOG"
exit 0
EOF
  chmod +x "$BIN/$cmd"
done
# rebuild.sh rewrites its path with HOME/.nix-profile/bin first, so
# the stubs must live there too or the system git/nix earlier in that
# list would win over $BIN in a non-sandbox run.
mkdir -p "$HOME_DIR/.nix-profile/bin"
cp "$BIN/git" "$BIN/nix" "$HOME_DIR/.nix-profile/bin/"
# Failure-injection wrappers for backup-zed.sh. Delegate all non-injected
# operations to the real commands so each regression exercises the script's
# ordinary filesystem behavior.
cat > "$HOME_DIR/.nix-profile/bin/cp" <<'EOF'
#!/bin/sh
if [ "${FAIL_BACKUP_CP:-0}" = 1 ] && [ "$2" = "./.zed/settings.json" ]; then
  case "$3" in ./.zed/.settings.json.bak.*) exit 1 ;; esac
fi
if [ "${FAIL_RESTORE_CP:-0}" = 1 ]; then
  case "$2:$3" in ./.zed/.settings.json.bak.*:./.zed/settings.json) exit 1 ;; esac
fi
if [ "${FAIL_RESTORE_INDEX_CP:-0}" = 1 ]; then
  case "$2:$3" in ./.zed/.index.json.bak.*:./.zed/index.json) exit 1 ;; esac
fi
exec "$REAL_CP" "$@"
EOF
cat > "$HOME_DIR/.nix-profile/bin/mv" <<'EOF'
#!/bin/sh
if [ "${FAIL_PUBLISH_MV:-0}" = 1 ] && [ "$3" = "./.zed/index.json" ]; then
  exit 1
fi
if [ "${FAIL_PUBLISH_INSTALLED_MV:-0}" = 1 ] && [ "$3" = "./.zed/installed.txt" ]; then
  exit 1
fi
exec "$REAL_MV" "$@"
EOF
cat > "$HOME_DIR/.nix-profile/bin/rm" <<'EOF'
#!/bin/sh
if [ "${FAIL_ROLLBACK_RM:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in
      ./.zed/settings.json|./.zed/index.json) exit 1 ;;
    esac
  done
fi
exec "$REAL_RM" "$@"
EOF
chmod +x "$HOME_DIR/.nix-profile/bin/cp" "$HOME_DIR/.nix-profile/bin/mv" \
  "$HOME_DIR/.nix-profile/bin/rm"

# --- rebuild.sh fixture -------------------------------------------------------
REBUILD_WORK="$TMP_ROOT/rebuild"
mkdir -p "$REBUILD_WORK"
cp "$SELF_DIR/rebuild.sh" "$REBUILD_WORK/rebuild.sh"
cat > "$REBUILD_WORK/simple-rebuild.sh" <<EOF
#!/bin/sh
echo "simple-rebuild.sh \$*" >> "$LOG"
exit 0
EOF
chmod +x "$REBUILD_WORK/simple-rebuild.sh"

# --- backup-zed.sh fixture ----------------------------------------------------
BACKUP_WORK="$TMP_ROOT/backup"
mkdir -p "$BACKUP_WORK/.zed"
cp "$SELF_DIR/backup-zed.sh" "$BACKUP_WORK/backup-zed.sh"
mkdir -p "$HOME_DIR/.config/zed" \
  "$HOME_DIR/Library/Application Support/Zed/extensions/installed/ext-a" \
  "$HOME_DIR/Library/Application Support/Zed/extensions/installed/ext-b"
echo '{"fixture": "settings"}' > "$HOME_DIR/.config/zed/settings.json"
echo '{"fixture": "index"}' \
  > "$HOME_DIR/Library/Application Support/Zed/extensions/index.json"

RC=0
run_script() { # run_script <workdir> <script> [args...] — sets RC; out/err in $TMP_ROOT
  local work="$1" script="$2"; shift 2
  HOME="$HOME_DIR" PATH="$BIN:$PATH" \
    zsh "$work/$script" "$@" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
  RC=$?
}
expect_rc() { # expect_rc <desc> <want>
  if [ "$RC" -eq "$2" ]; then
    echo "ok: $1 (exit $2)"
  else
    fail "$1 — expected exit $2, got $RC; stderr: $(cat "$TMP_ROOT/err")"
  fi
}
expect_no_steps() { # expect_no_steps <desc>
  if [ ! -s "$LOG" ]; then
    echo "ok: $1 made no step calls"
  else
    fail "$1 made step calls — log: $(cat "$LOG")"
  fi
}

# --- rebuild.sh: --help / -h --------------------------------------------------
for arg in --help -h; do
  : > "$LOG"
  run_script "$REBUILD_WORK" rebuild.sh "$arg"
  expect_rc "rebuild.sh $arg exits 0" 0
  check "rebuild.sh $arg prints usage on stdout" \
    grep -q "Usage: rebuild.sh" "$TMP_ROOT/out"
  expect_no_steps "rebuild.sh $arg"
done

# --- rebuild.sh: unknown argument ---------------------------------------------
: > "$LOG"
run_script "$REBUILD_WORK" rebuild.sh --bogus
expect_rc "rebuild.sh --bogus exits 2" 2
check "rebuild.sh --bogus is named on stderr" \
  grep -q -- "--bogus" "$TMP_ROOT/err"
check "rebuild.sh --bogus prints usage on stderr" \
  grep -q "Usage: rebuild.sh" "$TMP_ROOT/err"
expect_no_steps "rebuild.sh --bogus"

# --- rebuild.sh: help followed by an extra argument (#1830) -------------------
# The complete argument list is validated before help is honored: a help
# flag plus anything else is a usage error naming the extra argument.
: > "$LOG"
run_script "$REBUILD_WORK" rebuild.sh --help unexpected
expect_rc "rebuild.sh --help unexpected exits 2" 2
check "rebuild.sh --help unexpected names the extra argument on stderr" \
  grep -q -- "unexpected" "$TMP_ROOT/err"
check "rebuild.sh --help unexpected prints usage on stderr" \
  grep -q "Usage: rebuild.sh" "$TMP_ROOT/err"
expect_no_steps "rebuild.sh --help unexpected"

: > "$LOG"
run_script "$REBUILD_WORK" rebuild.sh -h --bogus
expect_rc "rebuild.sh -h --bogus exits 2" 2
check "rebuild.sh -h --bogus names the extra argument on stderr" \
  grep -q -- "--bogus" "$TMP_ROOT/err"
check "rebuild.sh -h --bogus prints usage on stderr" \
  grep -q "Usage: rebuild.sh" "$TMP_ROOT/err"
expect_no_steps "rebuild.sh -h --bogus"

# --- rebuild.sh: no-argument control ------------------------------------------
: > "$LOG"
run_script "$REBUILD_WORK" rebuild.sh
expect_rc "rebuild.sh no argument exits 0" 0
if grep -q "^git " "$LOG"; then
  fail "rebuild.sh no argument must not run git (a053a8e) — log: $(cat "$LOG")"
else
  echo "ok: rebuild.sh no argument runs no git command"
fi
check "rebuild.sh no argument runs nix flake update" \
  grep -q "^nix .* flake update$" "$LOG"
check "rebuild.sh no argument runs ./simple-rebuild.sh" \
  grep -q "^simple-rebuild.sh" "$LOG"

# --- backup-zed.sh: --help / -h ------------------------------------------------
for arg in --help -h; do
  run_script "$BACKUP_WORK" backup-zed.sh "$arg"
  expect_rc "backup-zed.sh $arg exits 0" 0
  check "backup-zed.sh $arg prints usage on stdout" \
    grep -q "Usage: backup-zed.sh" "$TMP_ROOT/out"
  check "backup-zed.sh $arg copies no settings" \
    test ! -e "$BACKUP_WORK/.zed/settings.json"
done

# --- backup-zed.sh: unknown argument -------------------------------------------
run_script "$BACKUP_WORK" backup-zed.sh --bogus
expect_rc "backup-zed.sh --bogus exits 2" 2
check "backup-zed.sh --bogus is named on stderr" \
  grep -q -- "--bogus" "$TMP_ROOT/err"
check "backup-zed.sh --bogus prints usage on stderr" \
  grep -q "Usage: backup-zed.sh" "$TMP_ROOT/err"
check "backup-zed.sh --bogus copies no settings" \
  test ! -e "$BACKUP_WORK/.zed/settings.json"

# --- backup-zed.sh: no-argument control -----------------------------------------
run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh no argument exits 0" 0
check "backup-zed.sh no argument copies settings" \
  grep -q '"fixture": "settings"' "$BACKUP_WORK/.zed/settings.json"
check "backup-zed.sh no argument copies the extensions index" \
  grep -q '"fixture": "index"' "$BACKUP_WORK/.zed/index.json"
check "backup-zed.sh no argument lists installed extensions sorted" \
  grep -qx "ext-a" "$BACKUP_WORK/.zed/installed.txt"
check "backup-zed.sh no argument lists ext-b" \
  grep -qx "ext-b" "$BACKUP_WORK/.zed/installed.txt"


# --- backup-zed.sh: snapshot coherence on failure (#1787) ----------------------
# Seed a prior snapshot, then break one stage at a time: every failure
# must preserve all three prior outputs and exit nonzero, and the
# success path must publish all three new outputs with no temp files
# left behind.
ZED_OUT="$BACKUP_WORK/.zed"
ZED_SETTINGS_SRC="$HOME_DIR/.config/zed/settings.json"
ZED_INDEX_SRC="$HOME_DIR/Library/Application Support/Zed/extensions/index.json"
ZED_INSTALLED_SRC="$HOME_DIR/Library/Application Support/Zed/extensions/installed"

seed_prior_snapshot() {
  echo 'OLD settings' > "$ZED_OUT/settings.json"
  echo 'OLD index' > "$ZED_OUT/index.json"
  echo 'old-ext' > "$ZED_OUT/installed.txt"
}
check_prior_snapshot() { # check_prior_snapshot <desc-prefix>
  check "$1: settings preserved" grep -qx 'OLD settings' "$ZED_OUT/settings.json"
  check "$1: index preserved" grep -qx 'OLD index' "$ZED_OUT/index.json"
  check "$1: installed list preserved" grep -qx 'old-ext' "$ZED_OUT/installed.txt"
}
check_no_zed_leftovers() { # check_no_zed_leftovers <desc>
  check "$1" test "$(ls -A "$ZED_OUT" | LC_ALL=C sort | tr '\n' ' ')" = "index.json installed.txt settings.json "
}

# A failed backup copy must stop before publishing, leaving the pre-existing
# output (and the rest of the snapshot) untouched.
seed_prior_snapshot
FAIL_BACKUP_CP=1 run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh failed backup cp exits nonzero" 1
check "backup-zed.sh failed backup cp names the prior output" \
  grep -q "cannot back up prior output: ./.zed/settings.json" "$TMP_ROOT/err"
check_prior_snapshot "backup-zed.sh failed backup cp"
check_no_zed_leftovers "backup-zed.sh failed backup cp leaves no temp files"

# A failed publish rename restores every already-published output.
seed_prior_snapshot
FAIL_PUBLISH_MV=1 run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh failed publish mv exits nonzero" 1
check "backup-zed.sh failed publish mv reports successful rollback" \
  grep -q "prior snapshot restored" "$TMP_ROOT/err"
check_prior_snapshot "backup-zed.sh failed publish mv"
check_no_zed_leftovers "backup-zed.sh failed publish mv leaves no temp files"

# If restoration itself fails, the script must identify the inconsistent file
# and must not claim that the prior snapshot was restored.
seed_prior_snapshot
FAIL_PUBLISH_MV=1 FAIL_RESTORE_CP=1 run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh failed restore cp exits nonzero" 1
check "backup-zed.sh failed restore cp names inconsistent settings output" \
  grep -q "inconsistent output: could not restore ./.zed/settings.json" "$TMP_ROOT/err"
check "backup-zed.sh failed restore cp does not claim prior snapshot restored" \
  test "$(grep -c "prior snapshot restored" "$TMP_ROOT/err" || true)" -eq 0
check "backup-zed.sh failed restore cp preserves unaffected outputs" \
  grep -qx 'OLD index' "$ZED_OUT/index.json"
check_no_zed_leftovers "backup-zed.sh failed restore cp leaves no temp files"

# First publish (no prior snapshot) plus a publish failure: rollback must
# REMOVE the already-published outputs, not restore them (#2191). If the
# removal itself fails, the script must name the file it could not remove
# and report that the prior snapshot was not fully restored.
rm -f "$ZED_OUT/settings.json" "$ZED_OUT/index.json" "$ZED_OUT/installed.txt"
FAIL_PUBLISH_MV=1 FAIL_ROLLBACK_RM=1 run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh first-publish failed rollback rm exits nonzero" 1
check "backup-zed.sh first-publish failed rollback rm names the new settings output" \
  grep -q "could not remove new ./.zed/settings.json" "$TMP_ROOT/err"
check "backup-zed.sh first-publish failed rollback rm reports not fully restored" \
  grep -q "was not fully restored" "$TMP_ROOT/err"
check "backup-zed.sh first-publish failed rollback rm leaves the new settings in place" \
  grep -q '"fixture": "settings"' "$ZED_OUT/settings.json"
check "backup-zed.sh first-publish failed rollback rm publishes no index" \
  test ! -e "$ZED_OUT/index.json"
check "backup-zed.sh first-publish failed rollback rm publishes no installed list" \
  test ! -e "$ZED_OUT/installed.txt"

# Same first-publish rollback one publish step later: settings and index
# both published, the installed rename fails, and both removals fail —
# the index rm branch is named as well.
rm -f "$ZED_OUT/settings.json" "$ZED_OUT/index.json" "$ZED_OUT/installed.txt"
FAIL_PUBLISH_INSTALLED_MV=1 FAIL_ROLLBACK_RM=1 run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh first-publish late failure exits nonzero" 1
check "backup-zed.sh first-publish late failure names the new settings output" \
  grep -q "could not remove new ./.zed/settings.json" "$TMP_ROOT/err"
check "backup-zed.sh first-publish late failure names the new index output" \
  grep -q "could not remove new ./.zed/index.json" "$TMP_ROOT/err"
check "backup-zed.sh first-publish late failure reports not fully restored" \
  grep -q "was not fully restored" "$TMP_ROOT/err"
check "backup-zed.sh first-publish late failure leaves the new index in place" \
  grep -q '"fixture": "index"' "$ZED_OUT/index.json"
check "backup-zed.sh first-publish late failure publishes no installed list" \
  test ! -e "$ZED_OUT/installed.txt"

# A failed restore of the index (the last publish step fails after the
# index was already replaced) must name the index output, while the
# settings restore still succeeds (#2191).
seed_prior_snapshot
FAIL_PUBLISH_INSTALLED_MV=1 FAIL_RESTORE_INDEX_CP=1 run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh failed index restore cp exits nonzero" 1
check "backup-zed.sh failed index restore cp names the index output" \
  grep -q "could not restore ./.zed/index.json" "$TMP_ROOT/err"
check "backup-zed.sh failed index restore cp reports not fully restored" \
  grep -q "was not fully restored" "$TMP_ROOT/err"
check "backup-zed.sh failed index restore cp still restores settings" \
  grep -qx 'OLD settings' "$ZED_OUT/settings.json"
check "backup-zed.sh failed index restore cp leaves the new index in place" \
  grep -q '"fixture": "index"' "$ZED_OUT/index.json"
check "backup-zed.sh failed index restore cp preserves the installed list" \
  grep -qx 'old-ext' "$ZED_OUT/installed.txt"

# Missing source index: settings source is NEW, the index copy fails.
seed_prior_snapshot
echo 'NEW settings' > "$ZED_SETTINGS_SRC"
mv "$ZED_INDEX_SRC" "$ZED_INDEX_SRC.away"
run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh missing index exits nonzero" 1
check "backup-zed.sh missing index names the index source on stderr" \
  grep -q "extensions index source" "$TMP_ROOT/err"
check_prior_snapshot "backup-zed.sh missing index"
check_no_zed_leftovers "backup-zed.sh missing index leaves no temp files"
mv "$ZED_INDEX_SRC.away" "$ZED_INDEX_SRC"
echo 'NEW index' > "$ZED_INDEX_SRC"

# Failed enumeration: the installed-extensions dir is gone, find fails.
mv "$ZED_INSTALLED_SRC" "$ZED_INSTALLED_SRC.away"
run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh failed enumeration exits nonzero" 1
check "backup-zed.sh failed enumeration names the enumeration on stderr" \
  grep -q "cannot enumerate installed extensions" "$TMP_ROOT/err"
check_prior_snapshot "backup-zed.sh failed enumeration"
check_no_zed_leftovers "backup-zed.sh failed enumeration leaves no temp files"
mv "$ZED_INSTALLED_SRC.away" "$ZED_INSTALLED_SRC"

# Success: all three outputs publish the new backup, temps cleaned up.
run_script "$BACKUP_WORK" backup-zed.sh
expect_rc "backup-zed.sh success exits 0" 0
check "backup-zed.sh success publishes new settings" \
  grep -qx 'NEW settings' "$ZED_OUT/settings.json"
check "backup-zed.sh success publishes new index" \
  grep -qx 'NEW index' "$ZED_OUT/index.json"
check "backup-zed.sh success publishes new installed list" \
  grep -qx "ext-a" "$ZED_OUT/installed.txt"
check "backup-zed.sh success installed list has ext-b" \
  grep -qx "ext-b" "$ZED_OUT/installed.txt"
check_no_zed_leftovers "backup-zed.sh success leaves no temp files"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all rebuild/backup-zed tests passed"
