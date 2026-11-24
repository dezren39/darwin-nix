#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# test-harness.sh — shared hermetic test harness (design #1473, phase 1).
#
# Sourced, never executed. Gives a suite:
#
#   source lib/test-harness.sh
#   harness_init                       # scratch HOME/TMPDIR/XDG, EXIT cleanup
#   harness_ps_double_begin            # stub `ps` says "no processes" ...
#   ... assertions ...
#   harness_ps_double_end              # ... and only inside this block
#   harness_skip "reason"              # recorded; fatal in check mode
#   harness_summary                    # prints counts, exits nonzero on failure
#
# Why a harness at all: the flake checks repeated `HOME=$TMPDIR/home` by
# hand, each suite built its own ps double, and suites either skipped
# silently or failed on a host process table. One harness keeps the
# scratch-environment rules and the stub shebang rule in one place.
#
# Stub shebang rule: stubs are written with the RESOLVED interpreter
# (`command -v bash`), never `#!/usr/bin/env` — inside a nix build the
# env(1) lookup is not the one the developer's shell had, and a stray
# `bash` earlier on PATH changes what a stub means.
#
# Skip accounting: `harness_skip` records a skip and lets the suite
# continue. In check mode (HARNESS_CHECK=1, set by the flake checks) any
# skip fails the suite at `harness_summary`: a check that silently skips
# is a check that proves nothing.

# harness_init — create one scratch root and point HOME, TMPDIR and the
# XDG dirs into it. The EXIT trap removes the root. Idempotent.
harness_init() {
  [ -n "${HARNESS_ROOT:-}" ] && return 0
  HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-harness.XXXXXX")" || return 1
  export HARNESS_ROOT
  export HOME="$HARNESS_ROOT/home"
  export TMPDIR="$HARNESS_ROOT/tmp"
  export XDG_CONFIG_HOME="$HARNESS_ROOT/xdg/config"
  export XDG_CACHE_HOME="$HARNESS_ROOT/xdg/cache"
  export XDG_DATA_HOME="$HARNESS_ROOT/xdg/data"
  export XDG_STATE_HOME="$HARNESS_ROOT/xdg/state"
  mkdir -p "$HOME" "$TMPDIR" \
    "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
  # shellcheck disable=SC2064 # expand HARNESS_ROOT now, not at exit
  trap 'rm -rf "$HARNESS_ROOT"' EXIT
}

# harness_bin_dir — print the suite's stub bin directory.
harness_bin_dir() {
  printf '%s\n' "${HARNESS_STUB_BIN:-$HARNESS_ROOT/stubbin}"
}

# _harness_ensure_bin_dir — create the stub bin dir and remember it in
# this shell (a command substitution would lose the assignment).
_harness_ensure_bin_dir() {
  local dir="${HARNESS_STUB_BIN:-$HARNESS_ROOT/stubbin}"
  mkdir -p "$dir" || return 1
  HARNESS_STUB_BIN="$dir"
}

# harness_stub NAME BODY [ARGS...]
#   Write an executable stub NAME into the suite's stub bin dir. BODY is
#   the script text after the shebang; ARGS are passed to printf as
#   format arguments when BODY contains %s. The shebang is the resolved
#   bash path (never /usr/bin/env).
harness_stub() {
  local name="$1" body="$2"
  shift 2
  local dir bash_path
  _harness_ensure_bin_dir || return 1
  dir="$HARNESS_STUB_BIN"
  bash_path="$(command -v bash)" || { echo "harness: bash not found" >&2; return 1; }
  if [[ "$bash_path" == *$'\n'* ]]; then
    echo "harness: refusing a bash path with a newline" >&2
    return 1
  fi
  # shellcheck disable=SC2059 # deliberate: caller passes printf args
  printf '#!%s\n%s\n' "$bash_path" "$(printf "$body" "$@")" >"$dir/$name"
  chmod +x "$dir/$name"
}

# harness_ps_double_begin / harness_ps_double_end
#   Scope a `ps` double that reports no processes. The pair is explicit:
#   PATH is restored at end, so the rest of the suite still sees the real
#   process table (gotcha 3 in #1474 — never PATH-prepend for a whole
#   suite).
harness_ps_double_begin() {
  [ -n "${HARNESS_SAVED_PATH:-}" ] && return 0
  harness_init || return 1
  local dir
  _harness_ensure_bin_dir || return 1
  dir="$HARNESS_STUB_BIN"
  harness_stub ps 'exit 0' || return 1
  HARNESS_SAVED_PATH="$PATH"
  PATH="$dir:$PATH"
  export PATH
}

harness_ps_double_end() {
  [ -n "${HARNESS_SAVED_PATH:-}" ] || return 0
  PATH="$HARNESS_SAVED_PATH"
  export PATH
  unset HARNESS_SAVED_PATH
}

# harness_stat_double_begin / harness_stat_double_end
#   Scope a BSD-compatible `stat` double for tests running on GNU systems.
#   Supported forms are the formats clean.sh uses: -f %m, -f %u,
#   -f '%SB' -t FORMAT, and -f '%Sm' -t FORMAT. GNU-only -c is rejected.
#   The real stat path is captured before PATH changes and exported for the
#   stub. The shebang names the resolved bash path, so it works in a Nix
#   sandbox with no /usr/bin/env.
harness_stat_double_begin() {
  [ -n "${HARNESS_SAVED_STAT_PATH:-}" ] && return 0
  local dir bash_path
  _harness_ensure_bin_dir || return 1
  dir="$HARNESS_STUB_BIN"
  HARNESS_REAL_STAT="$(command -v stat)" || { echo "harness: stat not found" >&2; return 1; }
  bash_path="$(command -v bash)" || { echo "harness: bash not found" >&2; return 1; }
  case "$HARNESS_REAL_STAT$bash_path" in *$'\n'*) echo "harness: refusing a tool path with a newline" >&2; return 1 ;; esac
  export HARNESS_REAL_STAT
  {
    printf '#!%s\n' "$bash_path"
    cat <<'STAT_STUB'
[ -n "${HARNESS_REAL_STAT:-}" ] || exit 1
for _a in "$@"; do
  if [ "$_a" = "-c" ]; then echo "stat: illegal option -- c" >&2; exit 1; fi
done
_fmt=""; _tfmt=""; _file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) _fmt="$2"; shift 2 ;;
    -t) _tfmt="$2"; shift 2 ;;
    *) _file="$1"; shift ;;
  esac
done
[ -n "$_fmt" ] && [ -n "$_file" ] || exit 1
case "$_fmt" in
  '%m') "$HARNESS_REAL_STAT" -c '%Y' "$_file" ;;
  '%u') "$HARNESS_REAL_STAT" -c '%u' "$_file" ;;
  '%SB'|'%Sm')
    if [ "$_fmt" = '%SB' ]; then
      _epoch="$("$HARNESS_REAL_STAT" -c '%W' "$_file" 2>/dev/null)"
      # GNU filesystems may not record birth time; BSD stat always does.
      case "$_epoch" in ''|*[!0-9]*|0) _epoch="$("$HARNESS_REAL_STAT" -c '%Y' "$_file")" ;; esac
    else
      _epoch="$("$HARNESS_REAL_STAT" -c '%Y' "$_file")"
    fi
    date -d "@$_epoch" +"${_tfmt:-%Y-%m-%d %H:%M:%S}" ;;
  *) echo "stat shim: unsupported -f format: $_fmt" >&2; exit 1 ;;
esac
STAT_STUB
  } >"$dir/stat"
  chmod +x "$dir/stat" || return 1
  HARNESS_SAVED_STAT_PATH="$PATH"
  PATH="$dir:$PATH"
  export PATH
}

harness_stat_double_end() {
  [ -n "${HARNESS_SAVED_STAT_PATH:-}" ] || return 0
  PATH="$HARNESS_SAVED_STAT_PATH"
  export PATH
  unset HARNESS_SAVED_STAT_PATH
}

# harness_skip REASON — record a skip. In check mode every skip is a
# failure, reported at summary time. The counter default must be inline
# (`${HARNESS_SKIPS:-0}`): the real suites run `set -u`, and a bare
# `$((HARNESS_SKIPS + 1))` aborts on the first skip (#1914).
harness_skip() {
  HARNESS_SKIPS=$((${HARNESS_SKIPS:-0} + 1))
  echo "skip: $1"
}

# harness_summary — print the counts and exit accordingly.
#   Failures always fail. Skips fail only in check mode (HARNESS_CHECK=1).
harness_summary() {
  local failures="${HARNESS_FAILURES:-0}" skips="${HARNESS_SKIPS:-0}"
  echo "harness: $failures failure(s), $skips skip(s)"
  [ "$failures" -eq 0 ] || exit 1
  if [ "$skips" -gt 0 ] && [ "${HARNESS_CHECK:-0}" = "1" ]; then
    echo "harness: check mode forbids skips" >&2
    exit 1
  fi
  exit 0
}
