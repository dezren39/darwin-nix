#!/usr/bin/env bash
# Behaviour test for the mcpx darwin module's agent restart (developing-
# today/code PR 11453). It runs the module's REAL install and restart
# blocks, extracted from this host's evaluated activation scripts, with
# the fixed paths and launchctl redirected into a temp dir.
#
# Why it exists: on 2026-11-17 two switches installed a new mcpx agent
# and then failed before postActivation; the restart decision lived in a
# shell variable, so the next switch saw the copy already current and
# never restarted the daemon, which kept serving a config three switches
# stale ("no daemon reachable" for every client).
#
# Usage: mcpx-agent-restart.test.sh EXTRA_ACTIVATION_TEXT POST_ACTIVATION_TEXT
set -euo pipefail

extra_file=$1
post_file=$2
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mcpx-agent-restart-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
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

block() {
  sed -n "/# mcpx-agent-$2-begin/,/# mcpx-agent-$2-end/p" "$1"
}

install_block=$(block "$extra_file" install)
restart_block=$(block "$post_file" restart)
# Positive controls: an empty extraction would make every check below
# vacuous.
if [ -z "$install_block" ] || [ -z "$restart_block" ]; then
  echo "FAIL: mcpx-agent install/restart blocks not found in the activation scripts" >&2
  exit 1
fi

agent_src=$(printf '%s\n' "$install_block" | grep -o '/nix/store/[^ ]*-mcpx' | head -n 1)
if [ -z "$agent_src" ] || [ ! -e "$agent_src" ]; then
  echo "FAIL: agent wrapper store path not found in the install block" >&2
  exit 1
fi

mkdir -p "$tmp/bin" "$tmp/libexec"
cat >"$tmp/bin/launchctl" <<STUB
#!$(command -v bash)
echo "launchctl \$*" >>"$tmp/calls"
[ "\${FAIL_KICKSTART:-0}" = 1 ] && exit 1
exit 0
STUB
chmod +x "$tmp/bin/launchctl"

# Redirect the fixed paths and the root-only install flags; everything
# else is the module's own text.
rewrite() {
  sed -e "s|/usr/local/libexec/mcpx/mcpx|$tmp/libexec/mcpx|g" \
    -e "s|/bin/launchctl|$tmp/bin/launchctl|g" \
    -e "s|/usr/bin/install -o root -g wheel|install|g" \
    -e "s|/usr/bin/id -u [^)]*|id -u|g"
}
printf '%s\n' "$install_block" | rewrite >"$tmp/install.sh"
printf '%s\n' "$restart_block" | rewrite >"$tmp/restart.sh"
grep -q "$tmp/libexec/mcpx" "$tmp/install.sh" || {
  echo "FAIL: path rewrite did not apply to the install block" >&2
  exit 1
}

kickstarts() { grep -c kickstart "$tmp/calls" 2>/dev/null || true; }

# 1. A new agent is installed, then the activation fails before
#    postActivation (the restart block never runs).
bash "$tmp/install.sh" 2>/dev/null
check "install copies the agent" cmp -s "$agent_src" "$tmp/libexec/mcpx"

# 2. The next switch: the copy is already current, so nothing is
#    installed -- but the restart must still happen.
bash "$tmp/install.sh" 2>/dev/null
FAIL_KICKSTART=0 bash "$tmp/restart.sh"
check "restart happens after an activation that failed before postActivation" test "$(kickstarts)" -eq 1

# 3. A further switch with nothing changed does not restart again.
bash "$tmp/install.sh" 2>/dev/null
bash "$tmp/restart.sh"
check "no second restart once the agent was restarted" test "$(kickstarts)" -eq 1

# 4. A failed kickstart keeps the restart pending for the next switch.
printf 'stale\n' >"$tmp/libexec/mcpx"
bash "$tmp/install.sh" 2>/dev/null
FAIL_KICKSTART=1 bash "$tmp/restart.sh" 2>/dev/null
FAIL_KICKSTART=0 bash "$tmp/restart.sh"
check "a failed kickstart is retried on the next activation" test "$(kickstarts)" -eq 3

if [ "$failures" -ne 0 ]; then
  echo "$failures mcpx agent restart check(s) failed" >&2
  exit 1
fi
echo "All mcpx agent restart checks passed"
