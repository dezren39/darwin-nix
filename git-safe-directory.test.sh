#!/usr/bin/env bash
# #2012: exercise real Git ownership enforcement, not just flag spellings.
# GIT_TEST_ASSUME_DIFFERENT_OWNER simulates foreign ownership without sudo.
# All Git configuration and repositories are isolated from the invoking user.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$TMP_ROOT/xdg"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP_ROOT/global.gitconfig"
export GIT_TEST_ASSUME_DIFFERENT_OWNER=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset SCAN_HOME CALLER_USER_HOME
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
: > "$GIT_CONFIG_GLOBAL"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# Source the actual runtime policy; compare its exact generated values with
# the Nix declaration, including the empty reset and scoped /* suffixes.
. "$SELF_DIR/lib/git-trusted-roots.sh"
git_trusted_c_args
NIX_ROOTS="$(sed -n '/safe\.directory = \[/,/\];/p' "$SELF_DIR/gitSettings.nix" \
  | sed -n 's|^[[:space:]]*"/Users/drewry\.pope/\([^"]*\)".*|\1|p' | sort)"
RUNTIME_ROOTS="$(for leaf in "${GIT_TRUSTED_LEAVES[@]}"; do printf '%s\n' "$leaf" "$leaf/*"; done | sort)"
[ -n "$NIX_ROOTS" ] && [ "$NIX_ROOTS" = "$RUNTIME_ROOTS" ] || fail "Nix/runtime trust lists differ"
grep -q '"" # Reset inherited trust' "$SELF_DIR/gitSettings.nix" || fail "Nix config lacks inherited-trust reset"

expect_allowed() {
  if ! git "${GIT_TRUSTED_C_ARGS[@]}" -C "$1" rev-parse --absolute-git-dir >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    fail "trusted repository rejected: $1 ($(cat "$TMP_ROOT/err"))"
  fi
}
expect_denied() {
  local status
  git "${GIT_TRUSTED_C_ARGS[@]}" -C "$1" rev-parse --absolute-git-dir >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  status=$?
  [ "$status" -ne 0 ] && grep -q 'dubious ownership' "$TMP_ROOT/err" || fail "expected ownership refusal: $1 (exit $status)"
}

# Exact roots AND nested repos must work; similarly named siblings must not.
# First prove that Git's ownership test switch is active in this build.
git init -q "$TMP_ROOT/untrusted"
expect_denied "$TMP_ROOT/untrusted"
for leaf in "${GIT_TRUSTED_LEAVES[@]}"; do
  root="$HOME/$leaf"
  git init -q "$root"
  git init -q "$root/deep/repo"
  git init -q "$root-other"
  expect_allowed "$root"
  expect_allowed "$root/deep/repo"
  expect_denied "$root-other"
done

# A pre-existing global wildcard must not defeat the runtime policy.
git config --global --add safe.directory '*'
expect_denied "$TMP_ROOT/untrusted"
expect_allowed "$HOME/git/deep/repo"
if printf '%s\n' "${GIT_TRUSTED_C_ARGS[@]}" | grep -Fxq 'safe.directory=*'; then
  fail "runtime emits bare wildcard"
fi

# A descendant symlink out of the trust root is not recursively trusted.
ln -s "$TMP_ROOT/untrusted" "$HOME/git/escape"
expect_denied "$HOME/git/escape"
git_trusted_path "$HOME/git/escape" && fail "repair policy follows escaping symlink"
git_trusted_path "$HOME/git-other" && fail "repair policy accepts prefix sibling"
git_trusted_path "$HOME/git/deep/repo" || fail "repair policy rejects trusted path"
git_trusted_path "$HOME/git/deep/../deep/repo" || fail "repair policy rejects canonical trusted path"

# Exercise the actual discover wrapper (loaded from its declaration, without
# running unrelated discovery). It must reset inherited trust and emit the
# same policy after lazy initialization.
eval "$(sed -n '/^git_q() {/,/^}/p' "$SELF_DIR/git-discover-repos")"
_self_dir="$SELF_DIR"
GIT_TRUSTED_INIT=""
GIT_TRUSTED_C_ARGS=()
git_q -C "$HOME/git/deep/repo" rev-parse --absolute-git-dir >/dev/null 2>&1 || fail "discovery rejects trusted descendant"
git_q -C "$TMP_ROOT/untrusted" rev-parse --absolute-git-dir >/dev/null 2>&1 && fail "discovery trusts outside path"

# Drive the real ownership-repair function with a chown recorder, never
# change ownership. Force the repair-needed branch; its policy must gate all
# representations: ordinary .git, bare repositories, and gitdir pointers.
eval "$(sed -n '/^repair_git_ownership() {/,/^}/p' "$SELF_DIR/clean.sh")"
CALLER_USER="$(id -un)"
CALLER_USER_HOME="$HOME"
DRY_RUN=0
DISCOVERY_FILE="$TMP_ROOT/discovery.tsv"
CHOWN_LOG="$TMP_ROOT/chown.log"
WARN_LOG="$TMP_ROOT/warnings.log"
: > "$CHOWN_LOG"
: > "$WARN_LOG"
chown() { printf '%s\n' "$*" >> "$CHOWN_LOG"; }
warn() { printf '%s\n' "$*" >> "$WARN_LOG"; }
git_metadata_needs_repair() { return 0; }
git init -q --bare "$HOME/git/bare.git"
git init -q --bare "$TMP_ROOT/outside-bare.git"
mkdir -p "$HOME/git/escaped-metadata" "$HOME/git/escaped-pointer"
ln -s "$TMP_ROOT/untrusted/.git" "$HOME/git/escaped-metadata/.git"
printf 'gitdir: %s\n' "$TMP_ROOT/untrusted/.git" > "$HOME/git/escaped-pointer/.git"
# A legitimate separate gitdir still works when both locations are trusted.
git init -q --separate-git-dir "$HOME/git/separate.git" "$HOME/git/separate"
printf 'repo\t%s\n' "$HOME/git/deep/repo" "$HOME/git/bare.git" "$HOME/git/separate" \
  "$TMP_ROOT/untrusted" "$TMP_ROOT/outside-bare.git" "$HOME/git/escape" \
  "$HOME/git-other" "$HOME/git/escaped-metadata" "$HOME/git/escaped-pointer" > "$DISCOVERY_FILE"
repair_git_ownership > "$TMP_ROOT/repair.out"
for metadata in "$HOME/git/deep/repo/.git" "$HOME/git/bare.git" "$HOME/git/separate.git"; do
  grep -Fq -- "$metadata" "$CHOWN_LOG" || fail "trusted metadata not repaired: $metadata"
done
for forbidden in "$TMP_ROOT/untrusted" "$TMP_ROOT/outside-bare.git" "$HOME/git/escape" "$HOME/git-other"; do
  grep -Fq -- "$forbidden" "$CHOWN_LOG" && fail "repair escaped policy: $forbidden"
done
grep -q 'outside trusted roots' "$WARN_LOG" || fail "outside repair scope did not warn"
[ "$(wc -l < "$CHOWN_LOG" | tr -d ' ')" -eq 4 ] || fail "unexpected chown calls: $(cat "$CHOWN_LOG")"

# Missing policy must fail closed even for ordinary/bare Git directories.
saved_self="$SELF_DIR"
SELF_DIR="$TMP_ROOT/missing-policy"
: > "$CHOWN_LOG"
repair_git_ownership >/dev/null
[ ! -s "$CHOWN_LOG" ] || fail "repair ran without policy fragment"
SELF_DIR="$saved_self"
for script in clean.sh git-discover-repos lib/git-trusted-roots.sh; do
  bash -n "$SELF_DIR/$script" || fail "syntax: $script"
done
if [ "$failures" -gt 0 ]; then
  echo "git-safe-directory.test.sh: $failures failure(s)" >&2
  exit 1
fi
echo "git-safe-directory.test.sh: all checks passed (real Git ownership enforcement and scoped repair)"
