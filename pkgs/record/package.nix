# SPDX-License-Identifier: MIT OR Apache-2.0
#
# `record`: appends one JSON line to ~/git/ai_recordings.jsonl
# (instructions/recordings.md; developing-today/code#1853). It runs
# developing-today/code's bin/record.mjs, which never rejects input and never
# fails the caller.
#
# The source is the developing-today/code tree the opencode fork already pins
# for mcpx (flake.nix passes inputs.openchamber.inputs.opencode.inputs.mcpx-src),
# so `record` moves with that pin and needs no checkout. Only record.mjs and
# the one module it imports are copied: referring to the whole tree itself
# would keep all of it alive in the system closure.
{
  lib,
  runCommandLocal,
  writeShellApplication,
  nodejs,
  src,
}:

let
  scripts = runCommandLocal "record-mjs" { } ''
    mkdir -p "$out"
    cp ${src}/bin/record.mjs ${src}/bin/home-dir.mjs "$out/"
  '';
in
writeShellApplication {
  name = "record";
  # git is looked up on the caller's PATH: record.mjs uses it only to stamp
  # the repository and HEAD, and does without it.
  text = ''
    exec ${lib.getExe nodejs} ${scripts}/record.mjs "$@"
  '';
}
