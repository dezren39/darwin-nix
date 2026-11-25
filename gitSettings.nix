# SPDX-License-Identifier: MIT OR Apache-2.0
#
# gitSettings.nix — single source of truth for global git configuration.
#
# Imported by homePrograms.nix as `programs.git.settings`. This is the freeform
# gitconfig attrset in current home-manager: keys land directly in
# ~/.config/git/config.
#
# HISTORY / GOTCHA
#   These keys previously lived under `programs.git.settings.extraConfig`, which
#   emitted literal `[extraConfig "core"]` sections. Git ignores unknown
#   sections outright, so init.defaultBranch, core.editor, core.autocrlf,
#   core.bigFileThreshold and safe.directory were all silently inert. Keys must
#   sit directly under `settings`.
#
#   Note also that ~/.gitconfig (unmanaged, hand-written) is read AFTER
#   ~/.config/git/config, so anything it sets wins over this file. See
#   `just git-config-check`.
{
  user = {
    name = "Drewry Pope";
    # Personal identity by default: the GitHub noreply address for dezren39,
    # so a commit from any checkout on this machine attributes to the
    # personal account unless a conditional include says otherwise. The work
    # identity is NOT the default (dezren39/darwin-nix#2096): it lives in
    # gitIncludes.nix and home-manager applies it only inside work checkouts
    # (a gitdir under ~/workspace/github-work, or a vertexinc remote). Do not
    # put a work address back here — the git-identity flake check fails if
    # the default rendered from this file is one, and so does
    # `just git-config-check` on a deployed config.
    email = "11225574+dezren39@users.noreply.github.com";
  };

  init.defaultBranch = "main";
  # Scoped trust, not a global wildcard (dezren39/darwin-nix#2012,
  # CVE-2022-24765): exact entries trust only that repository; trailing
  # /* entries trust descendants (including ~/git/fleet worktrees).
  # A bare `*` used to opt every
  # repository out of the ownership check, silently trusting even
  # attacker-controlled paths owned by another user.
  #
  # Keep this list identical to lib/git-trusted-roots.sh (the runtime
  # twin sourced by git-discover-repos and clean.sh for their cross-user
  # -c overrides). `just git-config-check` fails if the two diverge.
  # /private/var/folders scratch worktrees stay out deliberately: Git
  # supports trailing /*, not interior globs; same-user checkouts avoid the
  # ownership gate anyway.
  safe.directory = [
    "" # Reset inherited trust, including a system-level bare wildcard.
    "/Users/drewry.pope/git"
    "/Users/drewry.pope/git/*"
    "/Users/drewry.pope/workspace/github-work"
    "/Users/drewry.pope/workspace/github-work/*"
    "/Users/drewry.pope/.local/share/opencode/worktree"
    "/Users/drewry.pope/.local/share/opencode/worktree/*"
    "/Users/drewry.pope/.config/nix"
    "/Users/drewry.pope/.config/nix/*"
  ];

  core = {
    editor = "vim";
    autocrlf = "input";
    bigFileThreshold = "16m";
    # Built-in filesystem monitor daemon (git >= 2.37). Stops `git status`
    # rescanning the whole worktree. A short-lived daemon is spawned per repo
    # on demand and idles out again.
    fsmonitor = true;
    untrackedCache = true;
  };

  filter.lfs = {
    clean = "git-lfs clean -- %f";
    smudge = "git-lfs smudge -- %f";
    process = "git-lfs filter-process";
    required = true;
  };

  # index.version=4 + index.skipHash + untrackedCache. skipHash makes the index
  # unreadable by git < 2.40; this machine runs 2.55.
  feature.manyFiles = true;

  fetch = {
    prune = true; # drop remote-tracking refs deleted upstream
    parallel = 0; # auto-parallelise multi-remote/submodule fetches
    writeCommitGraph = true;
  };
  # fetch.pruneTags is deliberately NOT set: it would delete local-only tags
  # that never existed on the remote.

  push = {
    autoSetupRemote = true; # no more `--set-upstream` on first push
    followTags = true;
  };

  rebase = {
    autoSquash = true;
    autoStash = true;
    updateRefs = true; # 2.38+: keep stacked branches pointing correctly
  };

  # Merge on a divergent pull. Chosen on conflict count alone.
  #
  # Measured on 2026-09-30 with local main diverged 6/53 from origin, carrying
  # a merge commit that resolved 38 add/add conflicts under pkgs/mcpx:
  #
  #   merge  origin/main -> main :  0 conflicts
  #   rebase main -> origin/main : 35 conflicts on the 1st of 6 commits
  #
  # Merge resolves once, against the final state of both sides. Rebase
  # re-resolves per replayed commit, and flattens merge commits by default --
  # so it discarded the commit that *recorded* that resolution and replayed the
  # raw pre-merge snapshots against a newer upstream. rerere cannot rescue
  # that: it keys on a hash of the conflict preimage, the upstream side of
  # every hunk had moved, and 154 cached resolutions produced 0 replays.
  #
  # `pull.ff = only` was tried in between. It refuses a divergent pull and
  # makes the caller choose, which is safer against surprises but produces the
  # *same* conflict count as merge once you then merge -- it only adds a
  # command. Conflict frequency and difficulty are the only criteria here, so
  # the automatic merge wins and ff-only is not set.
  #
  # The one case where rebase genuinely beats merge, recorded so it is not
  # rediscovered: rebase drops commits whose patch-id already exists upstream,
  # where merge keeps both. That is a duplicate-history win, not a conflict
  # win, so it does not change this setting.
  pull.rebase = false;

  # GitHub credential helpers, migrated from ~/.gitconfig. The leading empty
  # string resets any inherited helper list before appending gh's.
  credential = {
    "https://github.com".helper = [
      ""
      "!/run/current-system/sw/bin/gh auth git-credential"
    ];
    "https://gist.github.com".helper = [
      ""
      "!/run/current-system/sw/bin/gh auth git-credential"
    ];
  };

  merge.conflictStyle = "zdiff3"; # 2.35+, strictly better than diff3
  rerere = {
    enabled = true;
    autoUpdate = true;
  };

  diff = {
    algorithm = "histogram";
    colorMoved = "zebra";
    mnemonicPrefix = true;
    renames = "copies";
  };

  # difftastic (structural / syntax-aware diff) shorthands. `difft` ships with
  # the difftastic package. Kept as aliases rather than a global diff.external so
  # plain `git diff` stays line-based (safe for scripts / pipes / other tools).
  alias = {
    dft = "!GIT_EXTERNAL_DIFF=difft git diff"; # structural diff, working tree
    dfts = "!GIT_EXTERNAL_DIFF=difft git diff --staged"; # structural diff, staged
    dl = "!GIT_EXTERNAL_DIFF=difft git log -p --ext-diff"; # log with structural patches
    dshow = "!GIT_EXTERNAL_DIFF=difft git show --ext-diff"; # show a commit structurally
  };

  # Object-store performance. gc.auto is NOT disabled globally — it is set
  # per-repo by ./git-maintain-repos, so repos outside that script keep their
  # normal safety net.
  gc.writeCommitGraph = true;
  pack.writeReverseIndex = true;

  # Stashes are NOT per-worktree: `git rev-parse --git-path refs/stash` from
  # inside a linked worktree resolves to the common dir, so one stack is shared
  # by every worktree of a repo.
  #
  # Only stash@{0} is a real ref. Every older entry exists solely as a reflog
  # entry of refs/stash, which puts the whole stack under gc.reflogExpire --
  # default 90 days, or 30 for unreachable. So `gc` silently discards older
  # stashes, and `git reflog expire --all` discards them immediately. The
  # git-gc man page names "refs/stash" as its example <pattern> precisely
  # because this is the intended escape hatch.
  #
  # "never" is effectively free here: one stash exists across every repo on
  # this machine, so there is no size argument against keeping them forever.
  "gc"."refs/stash" = {
    reflogExpire = "never";
    reflogExpireUnreachable = "never";
  };

  branch.sort = "-committerdate";
  tag.sort = "version:refname";
  column.ui = "auto";
  log.date = "iso";
  help.autoCorrect = "prompt";
  transfer.credentialsInUrl = "warn";
}
