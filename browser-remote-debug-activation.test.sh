#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
wrapper="$script_dir/browser-remote-debug-activation.sh"
script="$script_dir/browser-remote-debug.py"
python=${PYTHON:-python3}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/browser-remote-debug-activation-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
printf '#!%s\n' "$(command -v bash)" >"$tmp/bin/service-event"
cat >>"$tmp/bin/service-event" <<'STUB'
set -euo pipefail
printf '%s\n' "$*" >>"$EVENT_LOG"
if [ "${FAIL_SERVICE_EVENT:-0}" = 1 ]; then
  exit 1
fi
STUB
chmod +x "$tmp/bin/service-event"

failures=0
check() {
  local name=$1
  shift
  if "$@"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    failures=$((failures + 1))
  fi
}

contains() {
  grep -Fq -- "$1" "$2"
}

seed() {
  local home=$1 rel=$2 contents=$3
  mkdir -p "$home/$(dirname -- "$rel")"
  printf '%s' "$contents" >"$home/$rel"
}

run_wrapper() {
  local home=$1 event_log=$2 stdout=$3 stderr=$4 fail_event=${5:-0}
  env HOME="$home" EVENT_LOG="$event_log" FAIL_SERVICE_EVENT="$fail_event" \
    PATH="$tmp/bin:$PATH" bash "$wrapper" "$python" "$script" service-event \
    >"$stdout" 2>"$stderr"
}

# 1. All browsers healthy -> exit 0, no failure event, Local State updated.
home="$tmp/all-good"
seed "$home" "Library/Application Support/Google/Chrome/Local State" '{"browser":{}}'
seed "$home" "Library/Application Support/net.imput.helium/Local State" '{"browser":{}}'
if run_wrapper "$home" "$tmp/all-good.events" "$tmp/all-good.out" "$tmp/all-good.err"; then
  status=0
else
  status=$?
fi
check "all-good wrapper exits 0" test "$status" -eq 0
check "all-good records no failure event" test ! -e "$tmp/all-good.events"
check "all-good updates Chrome" contains '"user-enabled":true' "$home/Library/Application Support/Google/Chrome/Local State"
check "all-good updates Helium" contains '"user-enabled":true' "$home/Library/Application Support/net.imput.helium/Local State"

# 2. Malformed Chrome Local State -> Helium still updated, failure recorded in service-events, wrapper exits 0.
home="$tmp/partial"
seed "$home" "Library/Application Support/Google/Chrome/Local State" '{broken json'
seed "$home" "Library/Application Support/net.imput.helium/Local State" '{"browser":{}}'
if run_wrapper "$home" "$tmp/partial.events" "$tmp/partial.out" "$tmp/partial.err"; then
  status=0
else
  status=$?
fi
check "partial failure wrapper exits 0 when event recorded" test "$status" -eq 0
check "partial failure updates Helium" contains '"user-enabled":true' "$home/Library/Application Support/net.imput.helium/Local State"
check "partial failure records Chrome in service-events" contains "browser-remote-debug configuration.failed unconfigured_browsers=Google Chrome" "$tmp/partial.events"

# 3. Malformed Chrome + service-event write failure -> wrapper exits 1 (never hides unrecorded failure).
home="$tmp/unrecorded"
seed "$home" "Library/Application Support/Google/Chrome/Local State" '{broken json'
if run_wrapper "$home" "$tmp/unrecorded.events" "$tmp/unrecorded.out" "$tmp/unrecorded.err" 1; then
  status=0
else
  status=$?
fi
check "unrecorded failure wrapper exits 1" test "$status" -eq 1
check "unrecorded failure names ERROR on stderr" contains "could not durably record unconfigured browsers: Google Chrome" "$tmp/unrecorded.err"

# 4. Wrong arg count -> exit 2.
if bash "$wrapper" only-one-arg >"$tmp/bad.out" 2>"$tmp/bad.err"; then
  status=0
else
  status=$?
fi
check "bad arg count exits 2" test "$status" -eq 2

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed." >&2
  exit 1
fi
echo "All browser-remote-debug-activation checks passed."
