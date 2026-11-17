#!/usr/bin/env bash
# Tests for the operator-script help contract (#1892): -h|--help is
# honored only as the sole argument. Every script below used to exit 0
# on `$1 == -h|--help` without looking at the rest of the command line,
# so `--help extra` and `-h --bogus` reported success while silently
# ignoring unaccounted input -- the same class #1830 (rebuild.sh) and
# #1888 (simple-rebuild.sh) fixed for their own parsers.
#
# Oracle per script (decidable, output + exit status):
#   <script> --help extra   -> exit 2, the extra argument is named
#   <script> -h --bogus     -> exit 2, --bogus is named
#   <script> --help         -> exit 0, usage printed
#   <script> -h             -> exit 0
# Help paths exit inside the argument parser, before any side effect;
# HOME is a scratch dir regardless.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}
ok() { echo "ok: $1"; }

SCRIPTS=(
  search.sh
  patch-vscode-insiders.sh
  install-vscode-patch-agent.sh
  var-folders-clean.sh
  backup-zed.sh
  code-install-extensions.sh
  full-clean.sh
  clean.sh
  symlinker.sh
  opencode-db-backup-prune.sh
  opencode-db-prune.sh
  opencode-db-vacuum.sh
  pkgs/brew-repair/brew-repair.sh
  pkgs/adopt/adopt.sh
)

for rel in "${SCRIPTS[@]}"; do
  script="$SELF_DIR/$rel"
  start=$failures

  out="$(bash "$script" --help extra 2>&1)"; rc=$?
  [[ $rc -eq 2 ]] || fail "$rel: --help extra expected exit 2, got $rc"
  grep -q "extra" <<<"$out" || fail "$rel: --help extra did not name the unaccounted argument"

  out="$(bash "$script" -h --bogus 2>&1)"; rc=$?
  [[ $rc -eq 2 ]] || fail "$rel: -h --bogus expected exit 2, got $rc"
  grep -q -- "--bogus" <<<"$out" || fail "$rel: -h --bogus did not name the unaccounted argument"

  out="$(bash "$script" --help 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] || fail "$rel: --help alone expected exit 0, got $rc"
  [[ -n "$out" ]] || fail "$rel: --help alone printed no usage"

  out="$(bash "$script" -h 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] || fail "$rel: -h alone expected exit 0, got $rc"

  [[ $failures -eq $start ]] && ok "$rel: help honored only as the sole argument"
done

if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all help-extra-args tests passed"
