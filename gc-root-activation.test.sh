#!/usr/bin/env bash
# gc-root-activation.test.sh — regression test for issue #1851.
#
# homeUser.nix's rootActivatedGeneration entry advances the durable
# home-manager-last-activated GC root to the generation being activated.
# It used to run entryBefore writeBoundary, so a failure in any later
# activation entry left the root pointing at a generation that never
# finished activating while the last good generation lost its GC
# protection. The entry is now anchored entryAfter every other entry in
# this configuration's built activation script, so the root advances
# only when the whole DAG has run.
#
# This test pins both halves of that fix:
#   1. the anchor in homeUser.nix names every other entry of the built
#      activate script (entry set verified 2026-11-17; see the comment
#      above rootActivatedGeneration in homeUser.nix), and
#   2. the behaviour: simulating the activation order with the root
#      entry last, a failing entry leaves the prior root intact, while
#      a fully successful run advances it. A control run with the root
#      entry first (the pre-fix order) shows the harness can tell the
#      difference.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
home_user="$script_dir/homeUser.nix"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gc-root-activation-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failures=0
check() {
  local name=$1
  shift
  if "$@"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    failures=$((failures + 1))
  fi
}

# --- 1. the anchor -------------------------------------------------------

# Extract the rootActivatedGeneration entry (declaration through its
# closing line) from homeUser.nix by line numbers. The declaration may
# be one line or split (nixfmt puts `lib.hm.dag.entryAfter` on the next
# line), so the entry is located by name; the closing line is two quote
# characters and a semicolon at a deeper-or-equal indent; the pattern
# uses wildcards for the quotes so no shell-quoting gymnastics are needed.
decl_line=$(grep -n 'rootActivatedGeneration' "$home_user" | cut -d: -f1)
close_line=$(awk -v s="$decl_line" 'NR > s && /^  *..;$/ { print NR; exit }' "$home_user")
entry_block="$tmp/entry-block.txt"
sed -n "${decl_line},${close_line}p" "$home_user" >"$entry_block"

check "entry block extracted" test -s "$entry_block"
check "entry no longer runs before writeBoundary" \
  bash -c "! grep -q 'entryBefore' '$entry_block'"
check "entry is anchored with entryAfter" \
  grep -q 'entryAfter' "$entry_block"

# Every other entry of the built activate script for this configuration
# (verified 2026-11-17) must be named in the anchor list, so nothing in
# the DAG can run after the root advance.
expected_anchors=(
  browserRemoteDebug
  checkFilesChanged
  checkLinkTargets
  createScreenshotsDir
  installAltTab
  installPackages
  linkGeneration
  mcpClients
  mcpxConfig
  onFilesChange
  openchamberDeploy
  removeStaleNpmPlaywright
  setupLaunchAgents
  setupSidePulse
  sops-nix
  trampolineApps
  writeBoundary
)
for name in "${expected_anchors[@]}"; do
  check "anchor includes $name" grep -q "\"$name\"" "$entry_block"
done

# The entry body still performs the same indirect-root advance.
check "entry still adds the indirect root" \
  grep -q 'home-manager-last-activated' "$entry_block"
check "entry still uses --indirect and --realise" \
  bash -c "grep -q -- '--indirect' '$entry_block' && grep -q -- '--realise' '$entry_block'"

# --- 2. the behaviour ----------------------------------------------------

# Stub nix-store: implements just --add-root <root> --indirect --realise
# <path> by pointing <root> at <path> (a symlink stands in for the
# indirect gcroot) and logging the call.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/nix-store" <<'STUB'
#!/bin/sh
set -eu
root="" target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --add-root) root=$2; shift 2 ;;
    --realise) target=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$root" "$target" >>"$ADD_ROOT_LOG"
ln -sfn "$target" "$root"
STUB
chmod +x "$tmp/bin/nix-store"

# The entry body, adapted for the harness the way tmux-navigator.test.sh
# adapts its block: `run` executes directly and the profile's absolute
# nix-store path is rewritten to the stub. The body starts two lines
# after the anchor list's closing bracket (the string's opening '' sits
# between them) and ends before the entry's closing line. Indents are
# wildcards: nixfmt indents the bracket, body and closing line deeper
# when the declaration is split.
body_start=$(awk '/^  *] *$/ { print NR + 2; exit }' "$entry_block")
body_end=$(awk '/^  *..;$/ { print NR - 1; exit }' "$entry_block")
entry_body="$tmp/entry-body.sh"
sed -n "${body_start},${body_end}p" "$entry_block" | sed \
  -e 's|/nix/var/nix/profiles/default/bin/nix-store|nix-store|' \
  -e 's|/bin/mkdir|mkdir|' \
  -e 's/^ *run /run /' >"$entry_body"
check "entry body extracted" grep -q 'nix-store --add-root' "$entry_body"

# run_activation <dir> <root-entry-position: first|last> <fail-at: mid|none>
# Simulates the built activate script: entries run in order and the
# script aborts at the first failing entry (activation semantics).
run_activation() {
  local home=$1 position=$2 fail_at=$3
  mkdir -p "$home/.local/state/nix/gcroots"
  export HOME="$home"
  export ADD_ROOT_LOG="$home/add-root.log"
  : >"$ADD_ROOT_LOG"
  local old_gen="$home/old-gen" new_gen="$home/new-gen"
  mkdir -p "$old_gen" "$new_gen"
  # The prior successful activation's durable root.
  ln -sfn "$old_gen" "$home/.local/state/nix/gcroots/home-manager-last-activated"
  newGenPath="$new_gen"
  run() { "$@"; }
  entry_root() { . "$entry_body"; }
  entry_mid() {
    if [ "$fail_at" = mid ]; then
      echo "simulated later-entry failure" >&2
      return 1
    fi
  }
  # The subshell runs with its own set -e (activation semantics: abort
  # at the first failing entry). It must not sit in a || context — that
  # would suppress set -e inside it — so the parent's set -e is lifted
  # while it runs and the status is captured from $?.
  local rc=0
  set +e
  (
    set -e
    export PATH="$tmp/bin:$PATH"
    if [ "$position" = first ]; then
      entry_root
      entry_mid
    else
      entry_mid
      entry_root
    fi
  ) 2>"$home/stderr.log"
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$home/rc"
}

# Failure with the root entry last (the fixed order): the prior root
# survives and the root is never advanced.
fail_home="$tmp/fail-last"
run_activation "$fail_home" last mid
check "failed activation leaves the prior root intact" \
  bash -c "[ \"\$(readlink '$fail_home/.local/state/nix/gcroots/home-manager-last-activated')\" = '$fail_home/old-gen' ]"
check "failed activation never calls add-root" \
  bash -c "[ ! -s '$fail_home/add-root.log' ]"
check "failed activation reports failure" \
  bash -c "[ \"\$(cat '$fail_home/rc')\" != 0 ]"

# Success with the root entry last: the root advances to the new
# generation.
ok_home="$tmp/ok-last"
run_activation "$ok_home" last none
check "successful activation advances the root" \
  bash -c "[ \"\$(readlink '$ok_home/.local/state/nix/gcroots/home-manager-last-activated')\" = '$ok_home/new-gen' ]"
check "successful activation reports success" \
  bash -c "[ \"\$(cat '$ok_home/rc')\" = 0 ]"

# Control — failure with the root entry first (the pre-fix order): the
# root has already advanced, which is the bug this test guards.
ctrl_home="$tmp/fail-first"
run_activation "$ctrl_home" first mid
check "control: root-first order advances the root despite failure" \
  bash -c "[ \"\$(readlink '$ctrl_home/.local/state/nix/gcroots/home-manager-last-activated')\" = '$ctrl_home/new-gen' ]"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all gc-root activation checks passed"
