#!/usr/bin/env bash
# lib/git-trusted-roots.sh — scoped `safe.directory` trust roots.
#
# Runtime twin of the `safe.directory` list in gitSettings.nix
# (dezren39/darwin-nix#2012, CVE-2022-24765). The global `*` wildcard is
# gone: an exact entry trusts that repository only; a trailing /* trusts
# repositories below it. Both forms are emitted for each development root.
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
# NOT covered, deliberately: /private/var/folders scratch worktrees.
# Git supports a trailing /*, not arbitrary interior globs. Those are
# same-user TMPDIR checkouts, so the ownership gate
# never fires for them; a root-run scan of somebody else's mostly ends
# in status=unknown, which clean.sh keeps (mark_dir), never deletes.

# Leaf names, relative to the scanned home. Keep identical to
# gitSettings.nix's safe.directory list (absolute form there).
GIT_TRUSTED_LEAVES=(
  git
  workspace/github-work
  .local/share/opencode/worktree
  .config/nix
)

GIT_TRUSTED_C_ARGS=()

# git_trusted_c_args — rebuild GIT_TRUSTED_C_ARGS from the current home.
# Safe under `set -u`; HOME is always set for a running shell.
git_trusted_c_args() {
  local _home="${SCAN_HOME:-${CALLER_USER_HOME:-$HOME}}" _leaf
  # Reset inherited multi-valued settings, including a system/global '*'.
  GIT_TRUSTED_C_ARGS=(-c safe.directory=)
  for _leaf in "${GIT_TRUSTED_LEAVES[@]}"; do
    GIT_TRUSTED_C_ARGS+=(-c "safe.directory=$_home/$_leaf" -c "safe.directory=$_home/$_leaf/*")
  done
}

# Ownership repair must check BOTH the discovered repository and its Git
# metadata. Resolve symlinks first, then compare whole path components:
# root-other and root/link -> outside must never inherit root's trust.
# Missing/inaccessible paths fail closed. Only existing approved roots
# participate; cd -P also handles a symlinked home (common on macOS).
git_trusted_path() {
  local _path _root _leaf _home="${SCAN_HOME:-${CALLER_USER_HOME:-$HOME}}"
  _path="$(cd -- "$1" 2>/dev/null && pwd -P)" || return 1
  for _leaf in "${GIT_TRUSTED_LEAVES[@]}"; do
    _root="$(cd -- "$_home/$_leaf" 2>/dev/null && pwd -P)" || continue
    case "$_path" in
      "$_root"|"$_root"/*) return 0 ;;
    esac
  done
  return 1
}
