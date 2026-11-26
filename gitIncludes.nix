# SPDX-License-Identifier: MIT OR Apache-2.0
#
# gitIncludes.nix — conditional git identity includes, imported by
# homePrograms.nix as `programs.git.includes`.
#
# The default identity in gitSettings.nix is the personal one. The work
# identity below is applied ONLY inside work checkouts — a gitdir under
# ~/workspace/github-work (the work tree root already listed in
# gitSettings.nix's safe.directory) — and nowhere else
# (dezren39/darwin-nix#2096).
#
# A remote-URL condition (includeIf hasconfig:remote.*.url:*vertexinc*)
# cannot do this job from the global config file: git evaluates includeIf
# conditions while reading that file, before the repository's own config
# (where remote.origin.url lives) is read, so the condition never matches.
# Proven by the git-identity flake check on git 2.51.1 (fleet-command run
# 45681917622): 17 of 18 checks passed and exactly the hasconfig case
# failed. Location is the scope; do not re-add a hasconfig entry here.
#
# This has to live behind home-manager's `includes` option, not inside
# gitSettings.nix: home-manager appends these includeIf blocks AFTER the
# settings file, so a matching include overrides the default for that
# repository only. Rendered through lib.generators.toGitINI (the
# /etc/gitconfig path in configuration.nix) an includeIf section would
# sort before [user], and the default would silently win everywhere.
#
# Keep the work address out of gitSettings.nix: the git-identity flake
# check renders that file and fails if its default identity is this
# address, and `just git-config-check` fails on a deployed config whose
# default is a work address.
[
  {
    condition = "gitdir:~/workspace/github-work/";
    contents.user.email = "drewry.pope@vertexinc.com";
  }
]
