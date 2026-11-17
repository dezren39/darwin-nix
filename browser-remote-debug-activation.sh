#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: browser-remote-debug-activation.sh PYTHON BROWSER_REMOTE_DEBUG_PY SERVICE_EVENT" >&2
  exit 2
fi

python=$1
script=$2
service_event=$3
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/browser-remote-debug-activation.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

set +e
"$python" "$script" >"$tmpdir/stdout" 2>"$tmpdir/stderr"
status=$?
set -e

cat "$tmpdir/stdout"
cat "$tmpdir/stderr" >&2

if [ "$status" -eq 0 ]; then
  exit 0
fi

failed_browsers=$(sed -n \
  's/^browser-remote-debug: [0-9][0-9]* of [0-9][0-9]* browsers not configured: //p' \
  "$tmpdir/stderr")
if [ "$status" -ne 1 ] || [ -z "$failed_browsers" ]; then
  echo "browser-remote-debug activation: ERROR: browser-remote-debug exited $status without a recognized failure summary; refusing to report success." >&2
  exit "$status"
fi

if ! "$service_event" browser-remote-debug configuration.failed "unconfigured_browsers=$failed_browsers"; then
  echo "browser-remote-debug activation: ERROR: could not durably record unconfigured browsers: $failed_browsers" >&2
  exit 1
fi

echo "browser-remote-debug activation: WARNING: remote-debug configuration failed for: $failed_browsers (recorded in service-events)." >&2
