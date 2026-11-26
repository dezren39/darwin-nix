#!/usr/bin/env bash
# Regression for #2068: the inline OIDC token mints and pm-dispatch
# task POSTs embedded in the two dispatch workflows must carry
# explicit curl deadlines, like the bounded calls in
# .github/scripts/pm-dispatch-launch.sh (#1997). An unbounded request
# can stall until the enclosing job timeout (10 minutes for the
# watcher, 30 for ci-fix), delaying or preventing task creation.
#
# Asserts, for each workflow file:
#   - every curl invocation line carries --connect-timeout and
#     --max-time on the invocation line itself;
#   - the file has exactly the expected number of curl invocations
#     (2: one OIDC mint, one task POST), so a new inline call cannot
#     slip in unpinned;
#   - every --max-time is below 600s, the smallest enclosing job
#     timeout across the two workflows.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"

fails=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

check_workflow() {
  local file="$1" expected_curls="$2"
  local path="$repo/.github/workflows/$file"
  if [ ! -f "$path" ]; then
    fail "$file: workflow file missing"
    return
  fi

  local curl_lines count line max_time
  curl_lines="$(grep -n 'curl ' "$path" || true)"
  count="$(printf '%s\n' "$curl_lines" | grep -c 'curl ' || true)"
  if [ "$count" -eq "$expected_curls" ]; then
    ok "$file: $expected_curls curl invocations"
  else
    fail "$file: expected $expected_curls curl invocations, found $count"
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if printf '%s' "$line" | grep -q -- '--connect-timeout [0-9]'; then
      ok "$file: connect timeout bounded (line ${line%%:*})"
    else
      fail "$file: curl invocation lacks --connect-timeout: $line"
    fi
    if printf '%s' "$line" | grep -q -- '--max-time [0-9]'; then
      ok "$file: total timeout bounded (line ${line%%:*})"
    else
      fail "$file: curl invocation lacks --max-time: $line"
    fi
  done <<<"$curl_lines"

  while IFS= read -r max_time; do
    [ -n "$max_time" ] || continue
    if [ "$max_time" -lt 600 ]; then
      ok "$file: --max-time ${max_time}s is below the 600s smallest job timeout"
    else
      fail "$file: --max-time ${max_time}s is not below the 600s smallest job timeout"
    fi
  done <<EOF
$(grep -o -- '--max-time [0-9]*' "$path" | awk '{print $2}')
EOF
}

check_workflow main-broken-watcher.yml 2
check_workflow flake-checks-build.yml 2

if [ "$fails" -ne 0 ]; then
  echo "workflow-dispatch-timeouts: $fails check(s) failed" >&2
  exit 1
fi
echo "all workflow dispatch timeout checks passed"
