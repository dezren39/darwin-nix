#!/usr/bin/env bash
# Clear a /private/var/folders-style root, keeping the zz directory
# itself but emptying its contents (#553, factored out for #557).
#
# Usage: var-folders-clean.sh <folders-root>
#
# Deletes every top-level entry of <folders-root> except zz, then
# deletes every entry inside zz (zz itself is kept). A missing root
# is a no-op. This is the exact sweep clean.sh runs with
# --tmpdir (CLEAN_TMPDIR=1); clean.sh calls this script so the test
# (var-folders-clean.test.sh) exercises the shipped logic, not a copy.
#
# A deletion that fails is named on stderr and the script exits 1
# once the rest of the sweep has run (#1262). An enumeration that
# fails is likewise named on stderr and exits 1 (#1321). No temp
# file holds the enumeration: mktemp honours TMPDIR, which on the
# real macOS layout lives inside the swept root, so the sweep
# itself could delete the file's directory mid-run (Codex review,
# PR #1322).
#
# The accounting must survive macOS's stock Bash 3.2 (#1896): the
# delete loops are fed by process substitution, so they run in
# this shell — not in a pipeline subshell — on every Bash version,
# and the failed counter needs no Bash 4.2+ pipeline option to
# survive. A process substitution's exit status is invisible to
# the script, so each enumeration is first probed by a synchronous
# find run whose status is read directly; the sweep run repeats
# the same find. (The pipeline form read the find status back
# from PIPESTATUS, but its loops only stayed in this shell via
# that Bash 4.2+ option, so on Bash 3.2 every failure count was
# lost and the sweep reported success.)
#
# The probe alone does not cover the sweep run (#2189): a failure
# that strikes only the repeated run — an entry removed or
# re-permissioned between probe and sweep, a transient I/O error,
# a partial traversal failure mid-run — would run the loop zero
# or partial times and still exit 0. So the sweep run's status is
# carried in band: the substitution appends one empty record —
# a record find itself can never print, since it prints full
# paths — only when the sweep find exits 0, and the loop notes
# seeing it. If the record is missing when the loop ends, the
# enumeration that fed the loop failed, and it is named and
# counted exactly like a probe failure.
set -uo pipefail

usage() {
  echo "usage: var-folders-clean.sh <folders-root>"
}

# Argument guard (#1157): exactly one root. A second positional was
# silently ignored (the named target was never cleaned, exit 0) and a
# flag-shaped first argument was treated as a missing root (a silent
# no-op). Reject both by name, with usage on stderr and exit 2, before
# any deletion. --help prints usage and exits 0. The no-argument case
# still fails through the ${1:?} expansion below, unchanged.
if [ $# -ge 1 ]; then
  case "$1" in
    -h|--help) if [ $# -gt 1 ]; then echo "var-folders-clean.sh: unexpected argument: $2" >&2; usage >&2; exit 2; fi; usage; exit 0 ;;
    -*) echo "var-folders-clean.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi
if [ $# -gt 1 ]; then
  echo "var-folders-clean.sh: unexpected argument: $2" >&2; usage >&2; exit 2
fi

folders="${1:?usage: var-folders-clean.sh <folders-root>}"

failed=0
if [ ! -d "$folders" ]; then
  echo "var-folders-clean.sh: $folders does not exist (nothing to do)"
fi
if [ -d "$folders" ]; then
  if ! find "$folders" -mindepth 1 -maxdepth 1 -print0 2>/dev/null >/dev/null; then
    failed=$((failed + 1))
    echo "var-folders-clean.sh: failed to enumerate: $folders" >&2
  else
    sweep_ok=0
    while IFS= read -r -d "" i; do
      if [ -z "$i" ]; then
        sweep_ok=1
        continue
      fi
      if [ "$(basename "$i")" != "zz" ] && ! rm -rf "$i" 2>/dev/null; then
        failed=$((failed + 1))
        echo "var-folders-clean.sh: failed to delete: $i" >&2
      fi
    done < <(find "$folders" -mindepth 1 -maxdepth 1 -print0 2>/dev/null && printf '\000')
    if [ "$sweep_ok" -eq 0 ]; then
      failed=$((failed + 1))
      echo "var-folders-clean.sh: failed to enumerate: $folders" >&2
    fi
    if [ -d "$folders/zz" ]; then
      if ! find "$folders/zz" -mindepth 1 -maxdepth 1 -print0 2>/dev/null >/dev/null; then
        failed=$((failed + 1))
        echo "var-folders-clean.sh: failed to enumerate: $folders/zz" >&2
      else
        sweep_ok=0
        while IFS= read -r -d "" i; do
          if [ -z "$i" ]; then
            sweep_ok=1
            continue
          fi
          if ! rm -rf "$i" 2>/dev/null; then
            failed=$((failed + 1))
            echo "var-folders-clean.sh: failed to delete: $i" >&2
          fi
        done < <(find "$folders/zz" -mindepth 1 -maxdepth 1 -print0 2>/dev/null && printf '\000')
        if [ "$sweep_ok" -eq 0 ]; then
          failed=$((failed + 1))
          echo "var-folders-clean.sh: failed to enumerate: $folders/zz" >&2
        fi
      fi
    fi
  fi
fi
if [ "$failed" -gt 0 ]; then
  echo "var-folders-clean.sh: $failed deletion(s) failed" >&2
  exit 1
fi
