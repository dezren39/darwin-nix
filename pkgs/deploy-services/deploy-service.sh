#!/usr/bin/env bash
# deploy-service — the shared core of the option-(c) deploy apps
# (dezren39/darwin-nix#1393).
#
# A deploy app (pkgs/deploy-services/default.nix) bakes the service's
# parameters into the environment and execs this script:
#
#   DEPLOY_NAME       deploy-openchamber | deploy-mcpx (for messages)
#   DEPLOY_UNIT       the systemd user unit (openchamber.service)
#   DEPLOY_LINK_REL   the stable entrypoint, relative to the state
#                     home (openchamber/start, mcpx/bin/mcpx)
#   DEPLOY_TARGET     the store path this flake's build of the
#                     service must end up behind the entrypoint
#   DEPLOY_HEALTH     openchamber | mcpx (which health check to run)
#
# What a deploy does, in order:
#
#   1. Validate the target (exists, executable) BEFORE touching
#      anything — the stable-entrypoints rule from
#      developing-today/code#14187: a bad target fails the deploy,
#      never the service.
#   2. Atomically repoint the stable entrypoint at the target (a
#      temporary symlink renamed over the old one), but only when it
#      does not already point there. The unit files are never
#      written — they stay Home Manager-owned.
#   3. Restart the unit when the entrypoint moved. When it did not
#      move, restart only if the service is not healthy (a deploy
#      must leave a healthy service behind, and restarting a healthy
#      one would reproduce the bounce-without-need the stable
#      entrypoints exist to prevent).
#   4. Health-check until the service answers or the retry budget
#      runs out. If a repointed service never becomes healthy, roll
#      the entrypoint back to the previous target and restart again:
#      a failed deploy leaves the old build running, not a down
#      service.
#
# systemctl is deliberately NOT one of the app's runtime inputs: the
# deploy must talk to the host's user manager through the host's
# systemctl, not a store copy pinned by this flake.
set -euo pipefail

name="${DEPLOY_NAME:?DEPLOY_NAME is set by the deploy app wrapper}"
unit="${DEPLOY_UNIT:?DEPLOY_UNIT is set by the deploy app wrapper}"
link_rel="${DEPLOY_LINK_REL:?DEPLOY_LINK_REL is set by the deploy app wrapper}"
target="${DEPLOY_TARGET:?DEPLOY_TARGET is set by the deploy app wrapper}"
health_kind="${DEPLOY_HEALTH:?DEPLOY_HEALTH is set by the deploy app wrapper}"

state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
link="$state_home/$link_rel"
health_tries="${DEPLOY_HEALTH_TRIES:-60}"
health_delay="${DEPLOY_HEALTH_DELAY:-0.5}"

fail() {
  echo "$name: $*" >&2
  exit 1
}

health_check() {
  case "$health_kind" in
    openchamber)
      # The managed serve answers on loopback; the triage probe for
      # epic #973 recorded HTTP 200 on the root path.
      curl -fsS -m 5 -o /dev/null "http://127.0.0.1:3000/" 2>/dev/null
      ;;
    mcpx)
      systemctl --user is-active --quiet "$unit" || return 1
      # The daemon's health is keyed by its config path (the socket
      # name derives from it), so ask through the very config the
      # unit itself was started with — read back from ExecStart —
      # rather than guessing a path that would name another socket.
      local exec_start config
      exec_start="$(systemctl --user show "$unit" -p ExecStart --value 2>/dev/null || true)"
      config="$(printf '%s' "$exec_start" | grep -o -- '--config [^ ;]*' | head -n 1 | cut -d' ' -f2 || true)"
      if [ -z "$config" ]; then
        config="$HOME/.config/mcpx/config.json"
      fi
      "$link" --config "$config" health >/dev/null 2>&1
      ;;
    *)
      echo "$name: unknown DEPLOY_HEALTH kind: $health_kind" >&2
      return 1
      ;;
  esac
}

wait_healthy() {
  local tries="$health_tries" announced=0
  while [ "$tries" -gt 0 ]; do
    if health_check; then
      return 0
    fi
    # Feedback, once per wait: with the default budget (60 tries x
    # 0.5s) a deploy can sit here for ~30s, and the rollback path
    # waits up to three times. Without this line a healthy-but-slow
    # start is indistinguishable from a hung deploy.
    if [ "$announced" -eq 0 ]; then
      echo "$name: waiting for $unit to become healthy (up to $health_tries checks)..."
      announced=1
    fi
    sleep "$health_delay"
    tries=$((tries - 1))
  done
  return 1
}

repoint() {
  # repoint <target>: atomically move the stable entrypoint.
  local to="$1" tmp
  mkdir -p "$(dirname "$link")"
  tmp="$link.tmp.$$"
  rm -f "$tmp"
  ln -s "$to" "$tmp"
  mv -f "$tmp" "$link"
}

restart() {
  systemctl --user restart "$unit" || fail "systemctl --user restart $unit failed"
}

# 1. Validate the target before touching anything.
[ -e "$target" ] || fail "target does not exist: $target"
[ -x "$target" ] || fail "target is not executable: $target"
command -v systemctl >/dev/null 2>&1 ||
  fail "systemctl not found: these apps deploy the Linux systemd user units (on macOS the deploy path is \`just switch\`)"

previous=""
if [ -L "$link" ]; then
  previous="$(readlink "$link")"
elif [ -e "$link" ]; then
  fail "entrypoint exists but is not a symlink (its creation is Home Manager's): $link"
fi

# 2+3. Unchanged entrypoint: no repoint, no restart of a healthy
# service — the deploy is a health-verified no-op.
if [ "$previous" = "$target" ]; then
  echo "$name: $link already points at $target"
  if wait_healthy; then
    echo "$name: $unit is healthy on the current build; nothing to do"
    exit 0
  fi
  echo "$name: $unit is not healthy; restarting it on the current build"
  restart
  wait_healthy || fail "$unit did not become healthy after a restart on the current build"
  echo "$name: $unit is healthy after the restart"
  exit 0
fi

# 2. Repoint (this is also the first-deploy path: Home Manager owns
# first-time creation, but a missing link here is created the same
# validated, atomic way rather than failing a clean-state deploy).
repoint "$target"
echo "$name: $link -> $target"

# 3. Restart through the unit — never by writing unit files.
restart

# 4. Verify, and roll back if the new build does not come up.
if wait_healthy; then
  echo "$name: $unit is healthy on $target"
  exit 0
fi

echo "$name: $unit did not become healthy on $target" >&2
if [ -n "$previous" ]; then
  repoint "$previous"
  systemctl --user restart "$unit" || true
  if wait_healthy; then
    fail "rolled back to $previous and the service is healthy again; the new build was NOT deployed"
  fi
  fail "rolled back to $previous but the service is still not healthy; investigate $unit"
fi
fail "$unit did not become healthy on $target and there is no previous target to roll back to"
