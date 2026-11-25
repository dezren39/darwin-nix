# SPDX-License-Identifier: MIT OR Apache-2.0
#
# gitIncludes.nix — conditional git identity includes, imported by
# homePrograms.nix as `programs.git.includes`.
#
# The default identity in gitSettings.nix is the personal one. The work
# identity below is applied ONLY where a condition matches — a checkout
# under ~/workspace/github-work (the work tree root already listed in
# gitSettings.nix's safe.directory), or any checkout whose remote URL
# names the work org — and nowhere else (dezren39/darwin-nix#2096).
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
let
  workIdentity = {
    user.email = "drewry.pope@vertexinc.com";
  };
in
[
  {
    condition = "gitdir:~/workspace/github-work/";
    contents = workIdentity;
  }
  {
    condition = "hasconfig:remote.*.url:*vertexinc*";
    contents = workIdentity;
  }
]
