#!/usr/bin/env bash
# Regression test for pkgs/alt-tab-debug.nix (#2041).
#
# The DEBUG flag is injected into upstream's Swift build phase by matching
# "-emit-executable -module-name AltTab". If upstream changes that spelling,
# replaceStrings silently returns the original phase, so the package builds
# as a normal build. The expression must now fail evaluation unless the
# needle occurs exactly once.
#
# This evaluates the REAL alt-tab-debug.nix against a stub upstream package
# and the real nixpkgs lib.
#
# Run: bash alt-tab-debug.test.sh (exit 0 = all passed)
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expr="$here/alt-tab-debug.nix"
fail=0

eval_with_phase() {
  nix-instantiate --eval --strict --raw --expr "
    let
      lib = (import <nixpkgs> {}).lib;
      base = {
        buildPhase = ''$1'';
        meta = { };
      };
      alt = base // { overrideAttrs = f: base // (f base); };
    in
      (import $expr { alt-tab-macos = alt; inherit lib; }).buildPhase
  " 2>&1
}

check_ok() {
  local name="$1" phase="$2" want="$3" got
  if got="$(eval_with_phase "$phase")"; then
    if [[ "$got" == *"$want"* ]]; then
      echo "PASS: $name"
    else
      echo "FAIL: $name: expected output containing [$want], got [$got]"
      fail=1
    fi
  else
    echo "FAIL: $name: evaluation failed: $got"
    fail=1
  fi
}

check_rejected() {
  local name="$1" phase="$2" want="$3" got
  if got="$(eval_with_phase "$phase")"; then
    echo "FAIL: $name: evaluation succeeded, expected rejection"
    fail=1
  elif [[ "$got" == *"$want"* ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name: rejected without expected message [$want]: $got"
    fail=1
  fi
}

check_ok "matching command gets -D DEBUG" \
  "swiftc -emit-executable -module-name AltTab src/*.swift" \
  "swiftc -D DEBUG -emit-executable -module-name AltTab src/*.swift"

check_rejected "missing command is rejected" \
  "swiftc -emit-library -module-name Other src/*.swift" \
  "exactly once, found 0"

check_rejected "ambiguous command is rejected" \
  "swiftc -emit-executable -module-name AltTab a.swift
swiftc -emit-executable -module-name AltTab b.swift" \
  "exactly once, found 2"

exit "$fail"
