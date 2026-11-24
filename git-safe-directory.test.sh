#!/usr/bin/env bash
# Regression test for dezren39/darwin-nix#2012: `safe.directory` trust
# must stay scoped (CVE-2022-24765). The global `*` wildcard opted every
# repository out of git's ownership check; the fix scopes trust to the
# development roots in exactly two places — gitSettings.nix (managed
# gitconfig) and lib/git-trusted-roots.sh (runtime twin for the
# cross-user -c overrides in git-discover-repos and clean.sh).
#
# The contracts pinned here:
#   1. No star wildcard remains in any safe.directory setting or -c flag.
#   2. The nix list and the fragment leaf list describe the same roots.
#   3. git-discover-repos really passes the scoped flags to git (a PATH
#      shim records the invocations; the shim fails so --follow reports
#      it, which is fine — what matters is WHAT was passed, and that no
#      '*' was).
#   4. clean.sh's repair path routes through GIT_TRUSTED_C_ARGS.
#   5. Docs no longer describe a wildcard.
#   6. Best-effort live check: if this machine HAS a managed global git
#      config with safe.directory entries, none of them is a wildcard.
#
# This drives the REAL scripts (no pasted copies) against fixture dirs.

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

# ─── 1. No star wildcard in any safe.directory line ─────────────────────────
for f in gitSettings.nix lib/git-trusted-roots.sh git-discover-repos clean.sh; do
  if grep -n 'safe\.directory.*\*' "$SELF_DIR/$f" >/dev/null 2>&1; then
    grep -n 'safe\.directory.*\*' "$SELF_DIR/$f" | head -5 >&2
    fail "star wildcard in safe.directory line ($f)"
  else
    echo "ok: no wildcard safe.directory in $f"
  fi
done

# ─── 2. nix list and fragment leaves describe the same roots ────────────────
NIX_ROOTS="$(sed -n '/safe\.directory = \[/,/\];/p' "$SELF_DIR/gitSettings.nix" \
  | grep -o '"/Users/drewry\.pope/[^"]*"' | tr -d '"' | sed 's|/Users/drewry\.pope/||' | sort)"
FRAG_LEAVES="$(sed -n '/^GIT_TRUSTED_LEAVES=(/,/^)/p' "$SELF_DIR/lib/git-trusted-roots.sh" \
  | grep -v '^GIT_TRUSTED_LEAVES=(\|^)' | tr -d ' ' | sort)"
[ -n "$NIX_ROOTS" ] || fail "parsed zero roots from gitSettings.nix"
[ -n "$FRAG_LEAVES" ] || fail "parsed zero leaves from lib/git-trusted-roots.sh"
if [ "$NIX_ROOTS" = "$FRAG_LEAVES" ]; then
  echo "ok: nix and fragment lists agree ($(echo "$NIX_ROOTS" | wc -l | tr -d ' ') roots)"
else
  echo "--- gitSettings.nix ---" >&2; echo "$NIX_ROOTS" >&2
  echo "--- fragment ---" >&2; echo "$FRAG_LEAVES" >&2
  fail "gitSettings.nix and lib/git-trusted-roots.sh lists diverge"
fi

# ─── 3. git-discover-repos passes scoped flags, never '*' ───────────────────
mkdir -p "$HOME/git/r1/.git" "$HOME/workspace/r2/.git"
mkdir -p "$TMP_ROOT/bin"
GIT_LOG="$TMP_ROOT/git-calls.log"
cat > "$TMP_ROOT/bin/git" <<EOF
#!/usr/bin/env bash
echo "GITSHIM: \$*" >> "$GIT_LOG"
exit 1
EOF
chmod +x "$TMP_ROOT/bin/git"
# --follow forces the follow loop, which shells out through git_q.
PATH="$TMP_ROOT/bin:$PATH" "$SELF_DIR/git-discover-repos" --path "$HOME/git/r1" --follow >/dev/null 2>&1
[ -s "$GIT_LOG" ] || fail "git shim was never invoked (git_q bypassed?)"
if grep -q 'safe\.directory=\*' "$GIT_LOG"; then
  fail "git invoked with star wildcard"
else
  echo "ok: no star wildcard passed to git"
fi
for leaf in git workspace .local/share/opencode/worktree .config/nix; do
  if grep -q "safe\\.directory=$HOME/$leaf" "$GIT_LOG"; then
    echo "ok: scoped root passed for $leaf"
  else
    fail "scoped root missing from git invocation: $leaf"
  fi
done

# ─── 4. clean.sh repair path uses the scoped args ───────────────────────────
if grep -q 'GIT_TRUSTED_C_ARGS' "$SELF_DIR/clean.sh"; then
  echo "ok: clean.sh routes repair through GIT_TRUSTED_C_ARGS"
else
  fail "clean.sh does not reference GIT_TRUSTED_C_ARGS"
fi
bash -n "$SELF_DIR/clean.sh" || fail "clean.sh syntax check failed"
bash -n "$SELF_DIR/git-discover-repos" || fail "git-discover-repos syntax check failed"
bash -n "$SELF_DIR/lib/git-trusted-roots.sh" || fail "fragment syntax check failed"
echo "ok: bash -n passes on all touched scripts"

# ─── 5. Docs describe scoping, not a wildcard ───────────────────────────────
if grep -n 'safe\.directory=\*' "$SELF_DIR/ARCHITECTURE.md" >/dev/null 2>&1; then
  fail "ARCHITECTURE.md still documents safe.directory=*"
else
  echo "ok: ARCHITECTURE.md no longer documents a wildcard"
fi

# ─── 6. Managed config on this machine, if present, has no wildcard ─────────
# Scope is deliberate: only $HOME/.config/git/config is home-manager's
# output for this repo. Any other global config (another machine's
# ~/.gitconfig, this laptop's own settings) is out of scope here.
MANAGED="$HOME/.config/git/config"
if [ -f "$MANAGED" ]; then
  if git config --file "$MANAGED" --get-all safe.directory 2>/dev/null | grep -qx '\*'; then
    fail "managed gitconfig still trusts '*'"
  elif git config --file "$MANAGED" --get-all safe.directory 2>/dev/null | grep -q .; then
    echo "ok: managed gitconfig has no wildcard"
  else
    fail "managed gitconfig has no safe.directory entries at all"
  fi
else
  echo "ok: no managed gitconfig here (unmanaged machine) — skipped"
fi

if [ "$failures" -gt 0 ]; then
  echo "git-safe-directory.test.sh: $failures failure(s)" >&2
  exit 1
fi
echo "git-safe-directory.test.sh: all checks passed"
