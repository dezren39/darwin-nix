#!/usr/bin/env bash
# lib/git-trusted-roots.sh — scoped `safe.directory` trust roots.
#
# Runtime twin of the `safe.directory` list in gitSettings.nix
# (dezren39/darwin-nix#2012, CVE-2022-24765). The global `*` wildcard is
# gone: git honours a repo only if the repo or one of its parents is
# listed, so each entry below covers its whole subtree (~/git covers
# ~/git/fleet worktrees).
#
# Sourced — never executed — lazily by the two scripts that need a
# cross-user `-c` override (git-discover-repos's git_q and clean.sh's
# repair_git_ownership), AFTER the home they scan is final. Sourcing
# builds nothing; call git_trusted_c_args first, then read
# GIT_TRUSTED_C_ARGS. Entries are unconditional (never filtered by
# existence): a not-yet-created root is inert in git, and staying
# identical to gitSettings.nix is what `just git-config-check` verifies.
#
# Home resolution, in order: SCAN_HOME (git-discover-repos --user),
# CALLER_USER_HOME (clean.sh, correct even when running as root), HOME.
#
# NOT covered, deliberately: /private/var/folders/*/T/opencode scratch
# worktrees cannot be expressed as literal paths (git takes no globs
# here). Those are same-user TMPDIR checkouts, so the ownership gate
# never fires for them; a root-run scan of somebody else's mostly ends
# in status=unknown, which clean.sh keeps (mark_dir), never deletes.

# Leaf names, relative to the scanned home. Keep identical to
# gitSettings.nix's safe.directory list (absolute form there).
GIT_TRUSTED_LEAVES=(
  git
  workspace
  .local/share/opencode/worktree
  .config/nix
)

GIT_TRUSTED_C_ARGS=()

# git_trusted_c_args — rebuild GIT_TRUSTED_C_ARGS from the current home.
# Safe under `set -u`; HOME is always set for a running shell.
git_trusted_c_args() {
  local _home="${SCAN_HOME:-${CALLER_USER_HOME:-$HOME}}" _leaf
  GIT_TRUSTED_C_ARGS=()
  for _leaf in "${GIT_TRUSTED_LEAVES[@]}"; do
    GIT_TRUSTED_C_ARGS+=(-c "safe.directory=$_home/$_leaf")
  done
}
