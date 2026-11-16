#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# test-harness.sh -- shared test-environment harness (design #1473,
# phase 1 / #1474). The fourth contract sibling: lib/arg-probe.sh
# (#1145) governs what a suite asserts about argv, lib/outcome-probe.sh
# (#1339) governs operation outcomes, and this file governs the world a
# suite runs in -- scratch HOME/TMPDIR/XDG it builds itself, stubs
# executed the way they will really run, and skips that cannot pass
# silently in check mode.
#
# Sourced, never executed.
#
#   harness_init <suite-name>
#     One harness root per suite under the caller's TMPDIR, with scratch
#     HOME, TMPDIR and XDG_{CONFIG,CACHE,DATA,STATE}_HOME beneath it,
#     exported for every child process. An EXIT trap removes the root.
#     Idempotent: a second call is a no-op, so a suite may hand control
#     to a helper that also initializes.
#   harness_root, harness_home        -> the two paths
#   harness_stub_bin                  -> stub directory, created on demand
#   harness_stub_write <name>         -> reads the stub body on stdin
#     Writes an executable stub whose shebang is the interpreter resolved
#     now (command -v bash), never `#!/usr/bin/env` -- the env-shebang
#     spelling is the defect class from #1099/#1101/#1408/#1442 that made
#     by-name stubs unrunnable in the sandbox.
#   harness_ps_double begin|end
#     Scope-enter/exit the ps double that reports no processes, for the
#     sections whose script legitimately consults the host process table
#     (the db trio's check_not_running, #1451/#1816). Explicit pair: the
#     caller chooses the scope and PATH is restored at `end`.
#   harness_skip <reason>             -> SKIP line, counts skips
#   harness_skip_failed               -> 0 when every skip is acceptable
#     In check mode (TEST_HARNESS_CHECK=1, set by the flake checks) any
#     skip is a failure: a scenario that cannot run in the check
#     environment must not silently disappear (#1442).
#   harness_probe_matrix [fail-fn]    -> the harness's own rows
#     Drives scratch env, trap cleanup, stub shebang resolution, ps
#     double scoping, and check-mode skip accounting in isolated shells.

_harness_root() { printf '%s\n' "${TEST_HARNESS_ROOT:-}"; }

harness_init() {
  local _harness_name="${1:-suite}"
  [ -n "${TEST_HARNESS_ROOT:-}" ] && return 0
  TEST_HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-harness.XXXXXX")" || {
    echo "test-harness: could not create a harness root" >&2
    return 1
  }
  export TEST_HARNESS_ROOT
  HARNESS_SUITE="$_harness_name"
  export HARNESS_SUITE
  HOME="$TEST_HARNESS_ROOT/home"
  TMPDIR="$TEST_HARNESS_ROOT/tmp"
  XDG_CONFIG_HOME="$TEST_HARNESS_ROOT/xdg/config"
  XDG_CACHE_HOME="$TEST_HARNESS_ROOT/xdg/cache"
  XDG_DATA_HOME="$TEST_HARNESS_ROOT/xdg/data"
  XDG_STATE_HOME="$TEST_HARNESS_ROOT/xdg/state"
  export HOME TMPDIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME
  mkdir -p "$HOME" "$TMPDIR" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" \
    "$XDG_DATA_HOME" "$XDG_STATE_HOME" || return 1
  HARNESS_SKIPS=0
  export HARNESS_SKIPS
  trap 'harness_cleanup' EXIT
}

harness_root() { _harness_root; }
harness_home() { printf '%s\n' "$HOME"; }

harness_cleanup() {
  local _harness_status=$?
  if [ -n "${TEST_HARNESS_ROOT:-}" ] && [ -d "$TEST_HARNESS_ROOT" ]; then
    rm -rf "$TEST_HARNESS_ROOT"
  fi
  TEST_HARNESS_ROOT=""
  return "$_harness_status"
}

harness_stub_bin() {
  local _harness_bin="${TEST_HARNESS_ROOT:-/tmp}/bin"
  mkdir -p "$_harness_bin" || return 1
  printf '%s\n' "$_harness_bin"
}

harness_stub_write() {
  local _harness_name="$1" _harness_bin _harness_interp
  [ -n "$_harness_name" ] || {
    echo "test-harness: harness_stub_write needs a stub name" >&2
    return 1
  }
  _harness_bin="$(harness_stub_bin)" || return 1
  _harness_interp="$(command -v bash)" || _harness_interp=""
  [ -n "$_harness_interp" ] || {
    echo "test-harness: no bash on PATH to resolve a stub shebang" >&2
    return 1
  }
  {
    printf '#!%s\n' "$_harness_interp"
    cat
  } >"$_harness_bin/$_harness_name" || return 1
  chmod +x "$_harness_bin/$_harness_name" || return 1
  printf '%s\n' "$_harness_bin/$_harness_name"
}

harness_ps_double() {
  case "${1:-}" in
    begin)
      [ -z "${HARNESS_PS_SAVED_PATH:-}" ] || {
        echo "test-harness: ps double already active" >&2
        return 1
      }
      harness_stub_write ps >/dev/null <<'STUB'
# The db guards' process sense: no opencode processes, on every machine.
exit 0
STUB
      HARNESS_PS_SAVED_PATH="$PATH"
      PATH="$(harness_stub_bin):$PATH"
      export PATH
      ;;
    end)
      [ -n "${HARNESS_PS_SAVED_PATH:-}" ] || {
        echo "test-harness: ps double is not active" >&2
        return 1
      }
      PATH="$HARNESS_PS_SAVED_PATH"
      export PATH
      HARNESS_PS_SAVED_PATH=""
      ;;
    *)
      echo "test-harness: harness_ps_double needs begin or end" >&2
      return 2
      ;;
  esac
}

harness_check_mode() { [ "${TEST_HARNESS_CHECK:-0}" = "1" ]; }

harness_skip() {
  HARNESS_SKIPS=$(( ${HARNESS_SKIPS:-0} + 1 ))
  echo "SKIP: $*" >&2
  if harness_check_mode; then
    echo "test-harness: check mode makes a skip a failure: $*" >&2
    HARNESS_SKIP_FAILURES=$(( ${HARNESS_SKIP_FAILURES:-0} + 1 ))
  fi
  return 0
}

harness_skip_failed() { [ "${HARNESS_SKIP_FAILURES:-0}" -eq 0 ]; }

# The harness's own probe rows, driven through the suite's fail() so a
# failure reads like every other row in that suite. Each row runs in an
# isolated bash so the exported environment cannot leak between rows.
harness_probe_matrix() {
  local _harness_fail="${1:-fail}"
  local _harness_root _harness_case _harness_status _harness_out

  if ! command -v "$_harness_fail" >/dev/null 2>&1; then
    echo "test-harness: probe matrix needs a fail() function" >&2
    return 1
  fi
  _harness_root="$(mktemp -d)" || return 1
  _harness_case() { mkdir -p "$_harness_root/$1"; }

  # A suite gets a scratch HOME/TMPDIR/XDG it built, and the root is gone
  # after the suite's shell exits.
  _harness_case scratch
  _harness_out="$(env -u TEST_HARNESS_ROOT LC_HARNESS_LIB="${BASH_SOURCE[0]}" bash -c '
    . "$LC_HARNESS_LIB"
    harness_init probe
    printf "%s\n%s\n%s\n%s\n" "$HOME" "$TMPDIR" "$XDG_CONFIG_HOME" "$TEST_HARNESS_ROOT"
  ' </dev/null 2>"$_harness_root/scratch/err")" || {
    "$_harness_fail" "harness probe: scratch init failed (stderr: $(cat "$_harness_root/scratch/err"))"
    rm -rf "$_harness_root"
    return 0
  }
  set -- $_harness_out
  if [ $# -eq 4 ] && case "$1" in "$4"/home) true ;; *) false ;; esac && \
      case "$2" in "$4"/tmp) true ;; *) false ;; esac && \
      case "$3" in "$4"/xdg/config) true ;; *) false ;; esac; then
    if [ -e "$4" ]; then
      "$_harness_fail" "harness probe: EXIT trap did not remove the harness root"
    else
      echo "ok: harness probe: scratch HOME/TMPDIR/XDG under one root, removed on exit"
    fi
  else
    "$_harness_fail" "harness probe: scratch environment not under one root"
  fi

  # A by-name stub carries the resolved interpreter, never an env shebang,
  # and is executable.
  _harness_case stub
  _harness_out="$(LC_HARNESS_LIB="${BASH_SOURCE[0]}" bash -c '
    . "$LC_HARNESS_LIB"
    harness_init probe
    p="$(harness_stub_write hello <<"STUB"
echo hello-from-stub
STUB
)"
    printf "%s\n" "$p"
    head -n 1 "$p"
    [ -x "$p" ] && echo executable
    "$p"
  ' </dev/null 2>"$_harness_root/stub/err")" || {
    "$_harness_fail" "harness probe: stub builder failed (stderr: $(cat "$_harness_root/stub/err"))"
    rm -rf "$_harness_root"
    return 0
  }
  case "$_harness_out" in
    *"#!/usr/bin/env"*)
      "$_harness_fail" "harness probe: stub shebang is the env shebang (defect class #1099/#1442)" ;;
    *"#!$(command -v bash)"*"executable"*"hello-from-stub"*)
      echo "ok: harness probe: stub written with the resolved interpreter shebang and runs" ;;
    *)
      "$_harness_fail" "harness probe: stub builder output unexpected ($_harness_out)" ;;
  esac

  # The ps double is scope-entered: it shadows ps only between begin and
  # end, and end restores the caller's PATH.
  _harness_case ps
  _harness_out="$(LC_HARNESS_LIB="${BASH_SOURCE[0]}" bash -c '
    . "$LC_HARNESS_LIB"
    harness_init probe
    before="$PATH"
    harness_ps_double begin
    inside="$(ps 2>&1)"; inside_status=$?
    harness_ps_double end
    after="$PATH"
    [ "$before" = "$after" ] && echo restored
    [ "$inside_status" -eq 0 ] && [ -z "$inside" ] && echo quiet
    harness_ps_double end >/dev/null 2>&1 || echo refuses-unbalanced
  ' </dev/null 2>"$_harness_root/ps/err")" || {
    "$_harness_fail" "harness probe: ps double failed (stderr: $(cat "$_harness_root/ps/err"))"
    rm -rf "$_harness_root"
    return 0
  }
  case "$_harness_out" in
    *restored*quiet*refuses-unbalanced*)
      echo "ok: harness probe: ps double is scope-entered and restores PATH" ;;
    *)
      "$_harness_fail" "harness probe: ps double scoping unexpected ($_harness_out)" ;;
  esac

  # A skip is a skip in direct mode and a failure in check mode.
  _harness_case skip
  _harness_out="$(LC_HARNESS_LIB="${BASH_SOURCE[0]}" bash -c '
    . "$LC_HARNESS_LIB"
    harness_init probe
    harness_skip "probe skip row"
    harness_skip_failed && echo direct-ok || echo direct-fail
  ' </dev/null 2>/dev/null)"
  case "$_harness_out" in
    direct-ok) echo "ok: harness probe: a skip stays a skip in direct mode" ;;
    *) "$_harness_fail" "harness probe: a skip failed the direct-mode run ($_harness_out)" ;;
  esac
  _harness_out="$(TEST_HARNESS_CHECK=1 LC_HARNESS_LIB="${BASH_SOURCE[0]}" bash -c '
    . "$LC_HARNESS_LIB"
    harness_init probe
    harness_skip "probe skip row"
    harness_skip_failed && echo check-ok || echo check-fail
  ' </dev/null 2>/dev/null)"
  case "$_harness_out" in
    check-fail) echo "ok: harness probe: check mode turns any skip into a failure" ;;
    *) "$_harness_fail" "harness probe: check mode let a skip pass ($_harness_out)" ;;
  esac

  rm -rf "$_harness_root"
}
