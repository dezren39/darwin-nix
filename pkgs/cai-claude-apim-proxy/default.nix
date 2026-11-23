# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Vertex's APIM proxy for Claude Code (github:vertexinc/cai-claude-apim-proxy).
# Built from the source flake input, with its package-lock.json, so npm never
# runs on the machine. The runtime has no dependencies; the lockfile's only
# extra is jest, a dev dependency.
#
# Updates: the source is pinned by flake.lock. `nix flake update` (run by
# rebuild.sh) moves it to the newest main commit. The version is read from the
# source's package.json, so a bump needs no edit here. If the lockfile's
# dependencies change, npmDepsHash must be refreshed: set it to lib.fakeHash,
# build, and copy the hash Nix reports.
{
  lib,
  buildNpmPackage,
  src,
}:
buildNpmPackage {
  pname = "cai-claude-apim-proxy";
  version = (lib.importJSON "${src}/package.json").version;
  inherit src;
  npmDepsHash = "sha256-VUZeQDFl+UDokiJKW8/u7L6ccRyezB1NmhjCqpxCwTs=";
  dontNpmBuild = true;
  meta = {
    description = "Local proxy that lets Claude Code CLI talk to the Vertex AI Foundation APIM gateway";
    mainProgram = "cai-claude-apim-proxy";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
