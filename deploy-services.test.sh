#!/usr/bin/env bash
# Behaviour test for the option-(c) deploy core (dezren39/darwin-nix#1393).
#
# It drives the REAL pkgs/deploy-services/deploy-service.sh with
# systemctl and curl stubbed into a temp bin dir and a fake HOME, and
# pins the deploy contract from developing-today/code#14187:
#
#   - a bad target fails the deploy before anything is touched;
#   - an unchanged entrypoint is a health-verified no-op (no restart
#     of a healthy service);
#   - a changed entrypoint is repointed atomically, the unit is
#     restarted exactly once, and health is verified;
#   - a new build that never becomes healthy rolls the entrypoint
#     back to the previous target and restarts again;
#   - a second deploy of the same entrypoint while one holds the
#     per-link lock fails closed without touching the link (#2307);
#   - the mcpx health check asks through the config path the unit
#     itself was started with (read back from ExecStart), because
#     the daemon's socket name derives from that path.
#
# Usage: deploy-services.test.sh <path-to-deploy-service.sh>
set -euo pipefail

script=$1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/deploy-services-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
failures=0

export STUB_DIR="$tmp/stub"
export STUB_LOG="$tmp/calls.log"
mkdir -p "$STUB_DIR" "$tmp/bin" "$tmp/home"
: >"$STUB_LOG"

check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $name"
  else
    echo "FAIL: $name" >&2
    failures=$((failures + 1))
  fi
}

# --- stubs ---------------------------------------------------------------
#
# Stub shebangs name bash by the absolute path resolved HERE, not
# /usr/bin/env: the nix build sandbox has no /usr/bin, so an env
# shebang fails to exec at all there (the mcpx-agent-restart.test.sh
# stubs do the same). The deploy script's `command -v` validation
# still finds the stubs — it is the exec that would die.

bash_path=$(command -v bash)

{
  printf '#!%s\n' "$bash_path"
  cat <<'STUB'
echo "systemctl $*" >>"$STUB_LOG"
case "$*" in
  *is-active*)
    [ -f "$STUB_DIR/not-active" ] && exit 1
    exit 0
    ;;
  *show*)
    printf '{ path=stub ; argv[]=stub daemon --config %s ; }\n' "$STUB_DIR/rendered.json"
    exit 0
    ;;
  *restart*)
    n=$(cat "$STUB_DIR/restart-count" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" >"$STUB_DIR/restart-count"
    if [ "${RESTART_CLEARS_AT:-0}" = "$n" ]; then
      rm -f "$STUB_DIR/curl-fail"
    fi
    exit 0
    ;;
esac
exit 0
STUB
} >"$tmp/bin/systemctl"

{
  printf '#!%s\n' "$bash_path"
  cat <<'STUB'
echo "curl $*" >>"$STUB_LOG"
[ -f "$STUB_DIR/curl-fail" ] && exit 22
exit 0
STUB
} >"$tmp/bin/curl"
chmod +x "$tmp/bin/systemctl" "$tmp/bin/curl"

# --- fixtures --------------------------------------------------------------

make_target() {
  # make_target <name>: an executable fixture "service build" that
  # logs its invocations and fails while $STUB_DIR/fail-<name> exists.
  # Absolute bash shebang, like the stubs: no /usr/bin/env in the
  # nix build sandbox.
  local dir="$tmp/targets/$1"
  mkdir -p "$dir"
  cat >"$dir/bin" <<EOF
#!$bash_path
echo "target-$1 \$*" >>"\$STUB_LOG"
[ -f "\$STUB_DIR/fail-$1" ] && exit 1
exit 0
EOF
  chmod +x "$dir/bin"
  printf '%s' "$dir/bin"
}

old_target=$(make_target old)
new_target=$(make_target new)

state_home="$tmp/home/.local/state"
oc_link="$state_home/openchamber/start"
mcpx_link="$state_home/mcpx/bin/mcpx"

reset_state() {
  rm -rf "$tmp/home/.local"
  rm -f "$STUB_DIR/curl-fail" "$STUB_DIR/not-active" \
    "$STUB_DIR/fail-old" "$STUB_DIR/fail-new" "$STUB_DIR/restart-count"
  : >"$STUB_LOG"
  export RESTART_CLEARS_AT=0
}

restart_count() {
  grep -c 'systemctl .* restart' "$STUB_LOG" || true
}

run_deploy() {
  # run_deploy <health> <unit> <link-rel> <target>; sets rc, out.
  local health=$1 unit=$2 link_rel=$3 target=$4
  out="$tmp/last-out"
  DEPLOY_NAME="deploy-test" \
    DEPLOY_UNIT="$unit" \
    DEPLOY_LINK_REL="$link_rel" \
    DEPLOY_TARGET="$target" \
    DEPLOY_HEALTH="$health" \
    DEPLOY_HEALTH_TRIES=3 \
    DEPLOY_HEALTH_DELAY=0.1 \
    HOME="$tmp/home" \
    PATH="$tmp/bin:$PATH" \
    bash "$script" >"$out" 2>&1 && rc=0 || rc=$?
}

link_is() {
  [ "$(readlink "$1" 2>/dev/null || true)" = "$2" ]
}

no_healthy_line() {
  ! grep -q 'is healthy' "$1"
}

# --- scenario 1: unchanged entrypoint, healthy service = no-op -------------

reset_state
mkdir -p "$(dirname "$oc_link")"
ln -s "$new_target" "$oc_link"
run_deploy openchamber openchamber.service openchamber/start "$new_target"
check "unchanged+healthy exits 0" test "$rc" -eq 0
check "unchanged+healthy does not restart" test "$(restart_count)" -eq 0
check "unchanged+healthy still health-checks" grep -q 'curl ' "$STUB_LOG"
check "health-check curl carries a deadline (-m 5)" grep -q 'curl -fsS -m 5 ' "$STUB_LOG"
check "unchanged+healthy says what it did" grep -q 'already points' "$out"

# --- scenario 2: changed entrypoint, healthy new build = one restart -------

reset_state
mkdir -p "$(dirname "$oc_link")"
ln -s "$old_target" "$oc_link"
run_deploy openchamber openchamber.service openchamber/start "$new_target"
check "changed+healthy exits 0" test "$rc" -eq 0
check "changed+healthy repoints the link" link_is "$oc_link" "$new_target"
check "changed+healthy restarts exactly once" test "$(restart_count)" -eq 1

# --- scenario 3: missing target fails before touching anything -------------

reset_state
mkdir -p "$(dirname "$oc_link")"
ln -s "$old_target" "$oc_link"
run_deploy openchamber openchamber.service openchamber/start "$tmp/targets/ghost/bin"
check "missing target exits non-zero" test "$rc" -ne 0
check "missing target leaves the link alone" link_is "$oc_link" "$old_target"
check "missing target does not restart" test "$(restart_count)" -eq 0

# --- scenario 4: new build never healthy = rollback + second restart -------

reset_state
mkdir -p "$(dirname "$oc_link")"
ln -s "$old_target" "$oc_link"
touch "$STUB_DIR/curl-fail"
export RESTART_CLEARS_AT=2
run_deploy openchamber openchamber.service openchamber/start "$new_target"
check "unhealthy new build exits non-zero" test "$rc" -ne 0
check "unhealthy new build rolls the link back" link_is "$oc_link" "$old_target"
check "rollback restarts a second time" test "$(restart_count)" -eq 2
check "rollback is reported" grep -q 'rolled back' "$out"
check "health wait announces itself" grep -q 'waiting for openchamber.service to become healthy' "$out"

# --- scenario 5: clean state (no link yet) installs -------------------------

reset_state
run_deploy openchamber openchamber.service openchamber/start "$new_target"
check "clean state exits 0" test "$rc" -eq 0
check "clean state creates the link" link_is "$oc_link" "$new_target"
check "clean state restarts once" test "$(restart_count)" -eq 1

# --- scenario 6: unchanged entrypoint, unhealthy service = restart it -------

reset_state
mkdir -p "$(dirname "$oc_link")"
ln -s "$new_target" "$oc_link"
touch "$STUB_DIR/curl-fail"
export RESTART_CLEARS_AT=1
run_deploy openchamber openchamber.service openchamber/start "$new_target"
check "unchanged+unhealthy exits 0 after restart" test "$rc" -eq 0
check "unchanged+unhealthy restarts once" test "$(restart_count)" -eq 1
check "unchanged+unhealthy keeps the link" link_is "$oc_link" "$new_target"

# --- scenario 7: mcpx health asks through the unit's own config path --------

reset_state
mkdir -p "$(dirname "$mcpx_link")"
ln -s "$old_target" "$mcpx_link"
run_deploy mcpx mcpx.service mcpx/bin/mcpx "$new_target"
check "mcpx changed+healthy exits 0" test "$rc" -eq 0
check "mcpx repoints the link" link_is "$mcpx_link" "$new_target"
check "mcpx restarts exactly once" test "$(restart_count)" -eq 1
check "mcpx health uses the ExecStart config path" \
  grep -q "target-new --config $STUB_DIR/rendered.json health" "$STUB_LOG"

# --- scenario 8: non-executable mcpx target fails first ----------------------

reset_state
mkdir -p "$(dirname "$mcpx_link")"
ln -s "$old_target" "$mcpx_link"
chmod -x "$new_target"
run_deploy mcpx mcpx.service mcpx/bin/mcpx "$new_target"
check "non-executable target exits non-zero" test "$rc" -ne 0
check "non-executable target leaves the link alone" link_is "$mcpx_link" "$old_target"
check "non-executable target does not restart" test "$(restart_count)" -eq 0
chmod +x "$new_target"

# --- scenario 9: entrypoint that is not a symlink is refused -----------------

reset_state
mkdir -p "$(dirname "$oc_link")"
printf 'hand-maintained\n' >"$oc_link"
run_deploy openchamber openchamber.service openchamber/start "$new_target"
check "non-symlink entrypoint exits non-zero" test "$rc" -ne 0
check "non-symlink entrypoint is left untouched" grep -q 'hand-maintained' "$oc_link"
check "non-symlink entrypoint does not restart" test "$(restart_count)" -eq 0

# --- scenario 10: a held deploy lock fails a contender closed (#2307) -------

reset_state
mkdir -p "$(dirname "$oc_link")"
ln -s "$old_target" "$oc_link"
exec 8>"$oc_link.lock"
flock -n 8
run_deploy openchamber openchamber.service openchamber/start "$new_target"
check "locked contender exits non-zero" test "$rc" -ne 0
check "locked contender names the race" grep -q 'already in progress' "$out"
check "locked contender leaves the link alone" link_is "$oc_link" "$old_target"
check "locked contender does not restart" test "$(restart_count)" -eq 0
check "locked contender prints no healthy line" no_healthy_line "$out"
flock -u 8
exec 8>&-
run_deploy openchamber openchamber.service openchamber/start "$new_target"
check "after release the same deploy succeeds" test "$rc" -eq 0
check "after release the link is repointed" link_is "$oc_link" "$new_target"

# --- verdict -----------------------------------------------------------------

if [ "$failures" -gt 0 ]; then
  echo "deploy-services.test.sh: $failures failure(s)" >&2
  exit 1
fi
echo "deploy-services.test.sh: all scenarios passed"
