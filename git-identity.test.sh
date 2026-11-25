#!/usr/bin/env bash
# #2096: the default git identity is the personal noreply address, and the
# work identity applies only inside work checkouts — never as the global
# default. Drives real Git against two artifacts the git-identity flake
# check builds from the real sources:
#   RENDERED_GITCONFIG — gitSettings.nix rendered via lib.generators.toGitINI
#     with configuration.nix's overrides (the /etc/gitconfig twin).
#   HM_GITCONFIG — the per-user config home-manager generates from
#     homePrograms.nix's git block shape (settings + gitIncludes.nix).
# Source-level pins cover the wiring between the three files.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/home"
export HOME="$(cd "$TMP_ROOT/home" && pwd -P)"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset XDG_CONFIG_HOME
failures=0
checks=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { checks=$((checks + 1)); echo "ok: $*"; }

PERSONAL_EMAIL="11225574+dezren39@users.noreply.github.com"
WORK_EMAIL="drewry.pope@vertexinc.com"

[ -n "${RENDERED_GITCONFIG:-}" ] && [ -f "$RENDERED_GITCONFIG" ] \
  || fail "RENDERED_GITCONFIG not provided (run via the git-identity flake check)"
[ -n "${HM_GITCONFIG:-}" ] && [ -f "$HM_GITCONFIG" ] \
  || fail "HM_GITCONFIG not provided (run via the git-identity flake check)"
if [ "$failures" -gt 0 ]; then
  echo "git-identity.test.sh: missing artifacts, aborting" >&2
  exit 1
fi

# --- Source pins -----------------------------------------------------------
if grep -Fq "email = \"$PERSONAL_EMAIL\";" "$SELF_DIR/gitSettings.nix"; then
  ok "gitSettings.nix default email is the personal noreply address"
else
  fail "gitSettings.nix default email is not the personal noreply address"
fi
if grep -q 'drewry\.pope@vertexinc\.com' "$SELF_DIR/gitSettings.nix"; then
  fail "gitSettings.nix still contains the work email"
else
  ok "gitSettings.nix contains no work email"
fi
if grep -q 'TODO: move work email' "$SELF_DIR/gitSettings.nix"; then
  fail "gitSettings.nix still carries the #2096 TODO"
else
  ok "the #2096 TODO is resolved in gitSettings.nix"
fi
if grep -Fq 'condition = "gitdir:~/workspace/github-work/";' "$SELF_DIR/gitIncludes.nix" \
  && grep -Fq "user.email = \"$WORK_EMAIL\";" "$SELF_DIR/gitIncludes.nix"; then
  ok "gitIncludes.nix scopes the work identity behind the gitdir condition"
else
  fail "gitIncludes.nix does not declare the expected conditional work identity"
fi
# A hasconfig remote-URL condition can never fire from the global config
# file (git reads it before the repository's own config) — proven by run
# 45681917622, where exactly that case failed. Pin its absence so the dead
# condition is not re-added.
if grep -q 'hasconfig' "$SELF_DIR/gitIncludes.nix"; then
  # The word appears in the explanatory comment; a condition must not.
  if grep -Fq 'condition = "hasconfig:' "$SELF_DIR/gitIncludes.nix"; then
    fail "gitIncludes.nix re-added a hasconfig condition, which cannot fire from a global config"
  else
    ok "gitIncludes.nix carries no hasconfig condition (documented dead end only)"
  fi
else
  ok "gitIncludes.nix carries no hasconfig condition"
fi
if grep -Fq 'includes = import ./gitIncludes.nix;' "$SELF_DIR/homePrograms.nix"; then
  ok "homePrograms.nix wires gitIncludes.nix as programs.git.includes"
else
  fail "homePrograms.nix does not import gitIncludes.nix"
fi

# --- The /etc/gitconfig render (configuration.nix path) --------------------
rendered_email="$(git config --file "$RENDERED_GITCONFIG" --no-includes --get user.email || true)"
if [ "$rendered_email" = "$PERSONAL_EMAIL" ]; then
  ok "rendered system gitconfig default email is personal"
else
  fail "rendered system gitconfig default email is '$rendered_email'"
fi
rendered_name="$(git config --file "$RENDERED_GITCONFIG" --no-includes --get user.name || true)"
if [ "$rendered_name" = "Drewry Pope" ]; then
  ok "rendered system gitconfig keeps the user name"
else
  fail "rendered system gitconfig user.name is '$rendered_name'"
fi
if grep -q 'vertexinc\.com' "$RENDERED_GITCONFIG"; then
  fail "rendered system gitconfig contains a work address"
else
  ok "rendered system gitconfig contains no work address"
fi

# --- The home-manager generated config: structure --------------------------
hm_default_email="$(git config --file "$HM_GITCONFIG" --no-includes --get user.email || true)"
if [ "$hm_default_email" = "$PERSONAL_EMAIL" ]; then
  ok "home-manager gitconfig default email is personal"
else
  fail "home-manager gitconfig default email is '$hm_default_email'"
fi
include_targets="$(git config --file "$HM_GITCONFIG" --get-regexp 'includeif\..*\.path' | awk '{print $2}' | sort -u)"
include_count="$(git config --file "$HM_GITCONFIG" --get-regexp 'includeif\..*\.path' | wc -l | tr -d ' ')"
if [ "$include_count" -eq 1 ]; then
  ok "home-manager gitconfig carries the includeIf block"
else
  fail "home-manager gitconfig has $include_count includeIf blocks, want 1"
fi
for target in $include_targets; do
  if [ -f "$target" ] && [ "$(git config --file "$target" --get user.email || true)" = "$WORK_EMAIL" ]; then
    ok "include target $target carries only the work identity"
  else
    fail "include target $target missing or does not carry the work identity"
  fi
done
# Precedence: the includeIf blocks must come AFTER [user] in the generated
# file, or the default would override the conditional identity everywhere.
user_line="$(grep -n '^\[user\]' "$HM_GITCONFIG" | head -1 | cut -d: -f1)"
include_line="$(grep -n '^\[includeIf' "$HM_GITCONFIG" | head -1 | cut -d: -f1)"
if [ -n "$user_line" ] && [ -n "$include_line" ] && [ "$include_line" -gt "$user_line" ]; then
  ok "includeIf blocks render after [user] in the home-manager gitconfig"
else
  fail "includeIf blocks do not render after [user] (user=$user_line includeIf=$include_line)"
fi

# --- Real Git resolution against the home-manager config -------------------
export GIT_CONFIG_GLOBAL="$HM_GITCONFIG"
resolved_email() { (cd "$1" && git config --get user.email 2>/dev/null) || true; }
expect_email() {
  local dir="$1" want="$2" label="$3" got
  got="$(resolved_email "$dir")"
  if [ "$got" = "$want" ]; then
    ok "$label resolves to $want"
  else
    fail "$label resolves to '$got', want '$want'"
  fi
}

expect_email "$HOME" "$PERSONAL_EMAIL" "outside any repository"
git init -q -b main "$HOME/git/personal"
git -C "$HOME/git/personal" remote add origin "https://github.com/dezren39/darwin-nix.git"
expect_email "$HOME/git/personal" "$PERSONAL_EMAIL" "personal repository"
git init -q -b main "$HOME/workspace/github-work/proj"
expect_email "$HOME/workspace/github-work/proj" "$WORK_EMAIL" "work-tree repository (no remote)"
mkdir -p "$HOME/workspace/github-work/proj/deep/deeper"
expect_email "$HOME/workspace/github-work/proj/deep/deeper" "$WORK_EMAIL" "subdirectory of a work-tree repository"
git init -q -b main "$HOME/git/work-remote"
git -C "$HOME/git/work-remote" remote add origin "git@github.com:vertexinc/cai-claude-apim-proxy.git"
expect_email "$HOME/git/work-remote" "$PERSONAL_EMAIL" "work remote outside the work tree (location is the scope)"
work_name="$(cd "$HOME/workspace/github-work/proj" && git config --get user.name || true)"
if [ "$work_name" = "Drewry Pope" ]; then
  ok "work checkouts keep the same user name"
else
  fail "work checkout user.name is '$work_name'"
fi

if [ "$failures" -gt 0 ]; then
  echo "git-identity.test.sh: $failures failure(s) across $checks passed checks" >&2
  exit 1
fi
echo "git-identity.test.sh: all $checks checks passed (default identity is personal; work identity is conditional)"
