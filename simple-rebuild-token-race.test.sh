#!/usr/bin/env bash
# Regression test for #2052: concurrent token refreshes raced on the
# shared temp file.
#
# refresh_nix_access_token() rewrote every invocation through the same
# fixed temp path ($HOME/.local/share/nix/access-tokens.conf.tmp). Two
# overlapping ./s invocations collided: one writer's mv failed because
# the other had already renamed the shared temp file, and under set -e
# that rebuild aborted during token refresh before building; writers
# could also overwrite each other's in-progress contents, defeating the
# atomic-replacement intent of the rename.
#
# The fix gives every invocation its own temp name (mktemp in the same
# directory, renamed into place, removed on failure). This suite drives
# the REAL function -- extracted from simple-rebuild.sh, never a pasted
# copy -- under zsh (the script's interpreter) with a stubbed `gh`, both
# as a single-writer control and as barrier-started overlapping volleys,
# and asserts every invocation exits 0, the final file holds exactly one
# complete token line, and no temp debris is left behind.
#
# Run: ./simple-rebuild-token-race.test.sh
# It is run by the flake check `simple-rebuild-token-race-tests`.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/simple-rebuild.sh"

command -v zsh >/dev/null || { echo "zsh required" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $1"; }

# --- Extract the real function from the shipped script ---
FUNC="$TMP_ROOT/refresh.zsh"
awk '/^refresh_nix_access_token\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SCRIPT" >"$FUNC"
[ -s "$FUNC" ] || { echo "could not extract refresh_nix_access_token from simple-rebuild.sh" >&2; exit 1; }
grep -q 'access-tokens\.conf' "$FUNC" || { echo "extracted segment is not the token refresh function" >&2; exit 1; }

# One zsh runner per invocation: stubbed gh yielding this run's token,
# shared HOME so all runners hit the same target directory.
RUNNER="$TMP_ROOT/run.zsh"
cat >"$RUNNER" <<'ZSH'
set -eu
TEST_HOME="$1"; TEST_TOKEN="$2"; FUNC_FILE="$3"
export HOME="$TEST_HOME"
gh() { print -r -- "$TEST_TOKEN"; }
source "$FUNC_FILE"
refresh_nix_access_token >/dev/null
ZSH

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

run_refresh() { # home token -> exit status on stdout
  zsh "$RUNNER" "$1" "$2" "$FUNC" >/dev/null 2>&1
  echo $?
}

# --- Single-writer control ---
CTL_HOME="$TMP_ROOT/ctl-home"
mkdir -p "$CTL_HOME"
[ "$(run_refresh "$CTL_HOME" "control-token-1")" = "0" ] || fail "single refresh exits 0"
TARGET="$CTL_HOME/.local/share/nix/access-tokens.conf"
[ -f "$TARGET" ] || fail "single refresh writes access-tokens.conf"
[ "$(cat "$TARGET")" = "access-tokens = github.com=control-token-1" ] || fail "single refresh writes the complete token line"
[ "$(mode_of "$TARGET")" = "600" ] || fail "access-tokens.conf is mode 600 (got $(mode_of "$TARGET"))"
[ "$(mode_of "$CTL_HOME/.local/share/nix")" = "700" ] || fail "token dir is mode 700"
[ "$(ls -A "$CTL_HOME/.local/share/nix")" = "access-tokens.conf" ] || fail "single refresh leaves no temp debris"
ok "single-writer control: exit 0, complete line, 600/700 modes, no debris"

# --- Overlapping volleys ---
RACE_HOME="$TMP_ROOT/race-home"
mkdir -p "$RACE_HOME"
VOLLEY=32
ROUNDS=5
expected=""
for ((i = 1; i <= VOLLEY; i++)); do expected="${expected}access-tokens = github.com=volley-token-$i"$'\n'; done
round=0
volley_failures=$failures
while ((round < ROUNDS)); do
  round=$((round + 1))
  pids=""
  statuses="$TMP_ROOT/status.$round"
  : >"$statuses"
  for ((i = 1; i <= VOLLEY; i++)); do
    ( code=$(run_refresh "$RACE_HOME" "volley-token-$i"); echo "$code" >>"$statuses" ) &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids || fail "round $round: a refresh invocation failed to launch"
  nonzero="$(grep -vc '^0$' "$statuses" || true)"
  [ "$nonzero" = "0" ] || fail "round $round: $nonzero of $VOLLEY overlapping refreshes exited non-zero"
  final="$(cat "$RACE_HOME/.local/share/nix/access-tokens.conf")"
  echo "$expected" | grep -qxF "$final" || fail "round $round: final file is not one complete token line (got: $final)"
  leftovers="$(ls -A "$RACE_HOME/.local/share/nix")"
  [ "$leftovers" = "access-tokens.conf" ] || fail "round $round: temp debris left behind ($leftovers)"
done
((failures == volley_failures)) && ok "$ROUNDS overlapping volleys of $VOLLEY concurrent refreshes: all exit 0, atomic single-line result, no debris"

if ((failures > 0)); then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all token-race checks passed"
