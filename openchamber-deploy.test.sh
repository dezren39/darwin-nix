#!/usr/bin/env bash
# Regression test for the post-poll password guard in openchamber.nix.
# Extracts and executes the real home.activation.openchamberDeploy body with
# local tool stubs, covering poll expiry, unchanged credentials, and rotation;
# and the real openchamber-serve start script, covering a password that is
# present, arrives late (the post-reboot sops-nix race), or never arrives.
set -u

cd "$(dirname "$0")" || exit 1
failures=0

check() { # $1 name, $2 condition-result (0 = pass)
  if [ "$2" -eq 0 ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    failures=$((failures + 1))
  fi
}

work=$(mktemp -d)
if [ "${KEEP_TMP:-0}" = 1 ]; then
  echo "fixture retained: $work"
else
  trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work/bin"

# Extract the actual activation string, de-escape Nix shell expansions, and
# substitute only the Nix values which are outside this fixture's scope.
python3 - "$work/deploy.sh" <<'PYEOF'
import re, sys

src = open("openchamber.nix").read()
m = re.search(
    r"home\.activation\.openchamberDeploy = .*?''\n(.*?)\n      '';",
    src,
    re.S,
)
if not m:
    sys.exit("could not extract openchamberDeploy activation script")
body = m.group(1).replace("''${", "${")
replacements = {
    "state='${state}'": 'state="$ROOT/state"',
    'job="gui/$(/usr/bin/id -u)/${label}"':
        'job="gui/$(id -u)/org.nixos.openchamber"',
    "script='${start}'": 'script="$ROOT/start-script"',
    "target='${ocPkgs.opencode}/bin/opencode'":
        'target="$ROOT/opencode-bin"',
    "${ocPkgs.service-events}/bin/service-event": "service-event",
}
for old, new in replacements.items():
    body = body.replace(old, new)
for tool in ("id", "shasum", "awk", "readlink", "grep"):
    body = body.replace(f"/usr/bin/{tool}", tool)
for tool in ("sleep", "launchctl", "mkdir", "ln", "cat", "sh"):
    body = body.replace(f"/bin/{tool}", tool)
lines = body.split("\n")
indent = min(len(line) - len(line.lstrip(" ")) for line in lines if line.strip())
body = "\n".join(
    line[indent:] if line.startswith(" " * indent) else line for line in lines
)
open(sys.argv[1], "w").write(body + "\n")
PYEOF
[ -s "$work/deploy.sh" ]; check "deploy script extracted from the Nix module" $?

cat > "$work/bin/shasum" <<'EOF'
#!/bin/sh
if [ "$1" = "-a" ] && [ "$2" = "256" ]; then shift 2; fi
printf '%s\n' "$1" >> "$ROOT/shasum.log"
sha256sum "$1"
EOF
cat > "$work/bin/service-event" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ROOT/events.log"
EOF
chmod +x "$work/bin/shasum" "$work/bin/service-event"

prepare_case() { # $1 fixture root; $2 password text or missing; $3 previous marker
  local root=$1 password=$2 deployed=$3
  mkdir -p "$root/home/.config/openchamber" "$root/state/bin"
  printf '#!/bin/sh\nexit 0\n' > "$root/start-script"
  chmod +x "$root/start-script"
  printf 'binary\n' > "$root/opencode-bin"
  chmod +x "$root/opencode-bin"
  ln -sfn "$root/opencode-bin" "$root/state/bin/opencode"
  printf '%s\n' "$deployed" > "$root/state/deployed"
  if [ "$password" != missing ]; then
    printf '%s' "$password" > "$root/home/.config/openchamber/ui-password"
  fi
}

run_deploy() { # $1 fixture root; $2 output file; echoes exit status
  local root=$1 out=$2
  ROOT="$root" HOME="$root/home" PATH="$work/bin:$PATH" \
    DEPLOY_SCRIPT="$work/deploy.sh" bash -c '
      set -u
      launchctl() {
        if [ "$1" = print ]; then echo "state = running"; return 0; fi
        printf "%s\n" "$*" >> "$ROOT/calls.log"
      }
      run() { "$@"; }
      sleep() { :; }
      source "$DEPLOY_SCRIPT"
    ' > "$out" 2>&1
  local status=$?
  if [ "$status" -ne 0 ]; then cat "$out" >&2; fi
  echo "$status"
}

hash_text() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
real_hash=$(hash_text hunter2)

# Missing password after all 50 polls must fail before hashing or changing
# any service state.
missing="$work/missing"
prepare_case "$missing" missing "$missing/start-script:$real_hash"
rc=$(run_deploy "$missing" "$work/missing.out")
[ "$rc" -eq 1 ]; check "missing password fails activation" $?
grep -Fq "$missing/home/.config/openchamber/ui-password" "$work/missing.out"
check "failure names the unreadable password path" $?
[ "$(cat "$missing/state/deployed")" = "$missing/start-script:$real_hash" ]
check "missing password preserves deployed marker" $?
[ ! -s "$missing/shasum.log" ]; check "missing password is not hashed" $?
[ ! -s "$missing/calls.log" ]; check "missing password does not call launchctl" $?
[ ! -s "$missing/events.log" ]; check "missing password emits no service event" $?

# Present, unchanged password remains an uneventful no-op.
unchanged="$work/unchanged"
prepare_case "$unchanged" hunter2 "$unchanged/start-script:$real_hash"
rc=$(run_deploy "$unchanged" "$work/unchanged.out")
[ "$rc" -eq 0 ]; check "unchanged password activation succeeds" $?
grep -q 'deploy.unchanged running=1' "$unchanged/events.log"
check "unchanged password reports deploy.unchanged" $?
[ ! -s "$unchanged/calls.log" ]; check "unchanged password does not restart" $?
[ "$(cat "$unchanged/state/deployed")" = "$unchanged/start-script:$real_hash" ]
check "unchanged password preserves deployed marker" $?

# A real password rotation still takes the normal restart path and records
# the new, real hash.
rotation="$work/rotation"
old_hash=$(hash_text old-password)
prepare_case "$rotation" hunter2 "$rotation/start-script:$old_hash"
rc=$(run_deploy "$rotation" "$work/rotation.out")
[ "$rc" -eq 0 ]; check "rotated password activation succeeds" $?
grep -q 'deploy.restart cause=ui-password-changed' "$rotation/events.log"
check "real password rotation retains its restart cause" $?
grep -q 'kickstart -k' "$rotation/calls.log"
check "real password rotation restarts the running service" $?
[ "$(cat "$rotation/state/deployed")" = "$rotation/start-script:$real_hash" ]
check "rotation stores the real password hash" $?

# The start script (launchd's ProgramArguments) and the boot race: after a
# reboot sops-nix can decrypt the password after this agent starts, and the
# script used to start OpenChamber without it. Extract the real script, stub
# its sleep, service-event and the OpenChamber binary, and drive it with the
# password present, arriving late, and never arriving.
python3 - "$work/start.sh" <<'PYEOF'
import re, sys

src = open("openchamber.nix").read()
m = re.search(
    r'start = pkgs\.writeShellScript "openchamber-serve" \'\'\n(.*?)\n  \'\';',
    src,
    re.S,
)
if not m:
    sys.exit("could not extract the openchamber-serve start script")
body = m.group(1).replace("''${", "${")
replacements = {
    "exec ${openchamber}/bin/openchamber": 'exec "$ROOT/openchamber-stub"',
    "${openchamber}": "openchamber-pkg",
    "${state}": "$ROOT/state",
    "${config.environment.systemPath}": "$PATH",
    "${toString port}": "3000",
    "/run/current-system/sw/bin/service-event": "$ROOT/service-event",
    "/run/current-system/sw/bin/mcpx": "$ROOT/mcpx-stub",
    "/bin/sleep": "sleep",
}
for old, new in replacements.items():
    body = body.replace(old, new)
if "${" in body.replace("${OPENCHAMBER", ""):
    sys.exit("unsubstituted Nix interpolation left in the start script")
lines = body.split("\n")
indent = min(len(line) - len(line.lstrip(" ")) for line in lines if line.strip())
body = "\n".join(
    line[indent:] if line.startswith(" " * indent) else line for line in lines
)
open(sys.argv[1], "w").write(body + "\n")
PYEOF
[ -s "$work/start.sh" ]; check "start script extracted from the Nix module" $?

mkdir -p "$work/startbin"
# Counts polls; with LATE_AFTER set, writes the password on that poll, the
# way sops-nix's agent lands it mid-wait after a reboot.
cat > "$work/startbin/sleep" <<'EOF'
#!/bin/sh
n=$(( $(cat "$ROOT/sleeps" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ROOT/sleeps"
if [ -n "${LATE_AFTER:-}" ] && [ "$n" -ge "$LATE_AFTER" ]; then
  printf '%s' hunter2 > "$HOME/.config/openchamber/ui-password"
fi
EOF
chmod +x "$work/startbin/sleep"

prepare_start() { # $1 fixture root; $2 password text or missing
  local root=$1
  mkdir -p "$root/home/.config/openchamber" "$root/state/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$ROOT/events.log"\n' > "$root/service-event"
  printf '#!/bin/sh\nprintf "password=%%s\\n" "${OPENCHAMBER_UI_PASSWORD-<unset>}" > "$ROOT/exec.log"\nprintf "mcpx=%%s\\n" "${MCPX_CONFIG-<unset>}" >> "$ROOT/exec.log"\n' > "$root/openchamber-stub"
  # The oracle is readiness, independent of the implementation: a stub
  # gateway reports failure until the specified check (or forever).
  cat > "$root/mcpx-stub" <<'EOF'
#!/bin/sh
[ "$1" = --config ] && [ "$2" = "$HOME/.config/mcpx/config.json" ] && [ "$3" = health ] || exit 2
n=$(( $(cat "$ROOT/health-checks" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ROOT/health-checks"
[ "${MCPX_READY_AFTER:-1}" != never ] && [ "$n" -ge "${MCPX_READY_AFTER:-1}" ]
EOF
  chmod +x "$root/service-event" "$root/openchamber-stub" "$root/mcpx-stub"
  if [ "$2" != missing ]; then
    printf '%s' "$2" > "$root/home/.config/openchamber/ui-password"
  fi
}

run_start() { # $1 fixture root; $2 LATE_AFTER or empty; echoes exit status
  local root=$1
  ROOT="$root" HOME="$root/home" LATE_AFTER="$2" PATH="$work/startbin:$PATH" \
    bash "$work/start.sh" > "$root/out" 2>&1
  echo $?
}

present="$work/start-present"
prepare_start "$present" hunter2
rc=$(run_start "$present" "")
[ "$rc" -eq 0 ]; check "start: present password starts OpenChamber" $?
grep -qx 'password=hunter2' "$present/exec.log" 2>/dev/null
check "start: present password is passed to OpenChamber" $?
[ ! -e "$present/sleeps" ]; check "start: present password does not wait" $?
grep -Fxq "mcpx=$present/home/.config/mcpx/config.json" "$present/exec.log"
check "start: passes the stable mcpx config even without launchctl's environment" $?
[ "$(cat "$present/health-checks")" = 1 ]; check "start: checks mcpx readiness before launch" $?

gateway_late="$work/gateway-late"
prepare_start "$gateway_late" hunter2
rc=$(MCPX_READY_AFTER=5 run_start "$gateway_late" "")
[ "$rc" -eq 0 ] && [ -e "$gateway_late/exec.log" ] && [ "$(cat "$gateway_late/health-checks")" = 5 ]
check "start: waits for a late gateway, then starts OpenChamber" $?

gateway_never="$work/gateway-never"
prepare_start "$gateway_never" hunter2
rc=$(MCPX_READY_AFTER=never run_start "$gateway_never" "")
[ "$rc" -eq 1 ] && [ ! -e "$gateway_never/exec.log" ]
check "start: never launches OpenCode ahead of an unavailable gateway" $?
[ "$(cat "$gateway_never/health-checks")" = 301 ]
check "start: bounds gateway readiness polls so launchd can retry" $?

late="$work/start-late"
prepare_start "$late" missing
rc=$(run_start "$late" 5)
[ "$rc" -eq 0 ]; check "start: late password still starts OpenChamber" $?
grep -qx 'password=hunter2' "$late/exec.log" 2>/dev/null
check "start: late password is waited for, not skipped" $?

never="$work/start-never"
prepare_start "$never" missing
rc=$(run_start "$never" "")
[ "$rc" -eq 1 ]; check "start: password that never arrives exits for launchd to retry" $?
[ ! -e "$never/exec.log" ]; check "start: OpenChamber never starts without its password" $?
grep -q 'agent.no-ui-password' "$never/events.log" 2>/dev/null
check "start: missing password is recorded in the service event log" $?
grep -Fq "$never/home/.config/openchamber/ui-password" "$never/out"
check "start: failure names the unreadable password path" $?

if [ "$failures" -gt 0 ]; then
  echo "FAILURES: $failures"
  exit 1
fi
echo "ALL PASS"
