#!/usr/bin/env bash
# Regression test for install-vscode-patch-agent.sh (#945).
#
# #945: the installer printed "Installed and loaded" and exited 0 even
# when nothing was installed -- ~/Library/LaunchAgents was never created
# (so the plist write failed on a fresh account), and a failed
# `launchctl load` was never checked.
#
# This test drives the real installer with a scratch HOME and a stub
# launchctl on PATH:
#   missing-dir:  no LaunchAgents dir -> created, plist written, exit 0
#   failing load: stub load exits 42 -> exit non-zero naming the load
#                 step, no success banner (the plist write did happen)
#   blocked dir:  LaunchAgents is a regular file -> exit non-zero
#                 naming the directory/write step, no success banner
#   happy path:   dir pre-exists -> exit 0, banner, plist identical to
#                 the missing-dir run modulo the fixture HOME prefix
#   plist target: the written plist names the fixture HOME's patch
#                 script, never a hardcoded /Users/... path (#1366)
#   --help:       exit 0, usage printed, no plist written (#1177)
#   unknown arg:  exit 2 naming it, usage in output, no plist written,
#                 no success banner (#1177)
#   failed prep:  existing plist + injected mkdir failure -> the old
#                 agent is never unloaded, its plist is untouched, no
#                 success banner (#2151)
#   failed load:  existing plist + load fails for the new plist only
#                 -> the previous plist is restored and reloaded, both
#                 failures are reported, no success banner (#2151)
#   failed swap:  existing plist + injected mv failure -> the previous
#                 plist stays in place and the old agent is reloaded
#                 (#2151)
#
# Run: bash install-vscode-patch-agent.test.sh (exit 0 = all passed)
set -u

cd "$(dirname "$0")" || exit 1
INSTALLER="./install-vscode-patch-agent.sh"
PLIST_REL="Library/LaunchAgents/com.drewry.patch-vscode-insiders.plist"
failures=0

check() { # $1 name, $2 condition-result (0 = pass)
  if [ "$2" -eq 0 ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    failures=$((failures + 1))
  fi
}

make_home() { # $1 = home dir; seeds the patch script the installer requires
  mkdir -p "$1/nix"
  printf '# stub patch script\n' > "$1/nix/patch-vscode-insiders.sh"
}

make_stub() { # $1 = stub bin dir
  mkdir -p "$1"
  printf '#!/bin/sh\nif [ "$1" = "load" ]; then exit "${STUB_LOAD_RC:-0}"; fi\nexit 0\n' > "$1/launchctl"
  chmod +x "$1/launchctl"
}

run_installer() { # $1 = home, $2 = stub bin, $3 = load rc, $4 = output file; prints exit code
  HOME="$1" PATH="$2:$PATH" STUB_LOAD_RC="$3" bash "$INSTALLER" > "$4" 2>&1
  echo $?
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub="$work/bin"
make_stub "$stub"

# missing-dir: LaunchAgents does not exist; the installer must create it.
home1="$work/home1"
make_home "$home1"
rc=$(run_installer "$home1" "$stub" 0 "$work/out1")
[ "$rc" -eq 0 ]; check "945 missing-dir exits 0" $?
[ -f "$home1/$PLIST_REL" ]; check "945 missing-dir plist written" $?
grep -q "Installed and loaded" "$work/out1"; check "945 missing-dir banner printed" $?
grep -q "<string>com.drewry.patch-vscode-insiders</string>" "$home1/$PLIST_REL" 2>/dev/null
check "945 missing-dir plist names the agent" $?
grep -qF "<string>$home1/nix/patch-vscode-insiders.sh</string>" "$home1/$PLIST_REL" 2>/dev/null
check "1366 missing-dir plist names the checked patch script" $?
grep -q "/Users/" "$home1/$PLIST_REL" 2>/dev/null; [ $? -ne 0 ]
check "1366 missing-dir plist has no hardcoded /Users path" $?
cp "$home1/$PLIST_REL" "$work/golden.plist" 2>/dev/null

# failing load: stub launchctl load exits 42.
home2="$work/home2"
make_home "$home2"
mkdir -p "$home2/Library/LaunchAgents"
rc=$(run_installer "$home2" "$stub" 42 "$work/out2")
[ "$rc" -ne 0 ]; check "945 failing load exits non-zero" $?
grep -q "launchctl load failed" "$work/out2"; check "945 failing load names the load step" $?
grep -q "Installed and loaded" "$work/out2"; [ $? -ne 0 ]; check "945 failing load prints no success banner" $?
[ -f "$home2/$PLIST_REL" ]; check "945 failing load still wrote the plist" $?

# blocked dir: LaunchAgents exists as a regular file, so it cannot be
# created or written into.
home3="$work/home3"
make_home "$home3"
mkdir -p "$home3/Library"
printf 'not a directory\n' > "$home3/Library/LaunchAgents"
rc=$(run_installer "$home3" "$stub" 0 "$work/out3")
[ "$rc" -ne 0 ]; check "945 blocked dir exits non-zero" $?
grep -q "ERROR" "$work/out3"; check "945 blocked dir reports an error" $?
grep -q "Installed and loaded" "$work/out3"; [ $? -ne 0 ]; check "945 blocked dir prints no success banner" $?

# happy path: directory pre-exists; plist must be byte-identical to the
# missing-dir run, banner printed, exit 0.
home4="$work/home4"
make_home "$home4"
mkdir -p "$home4/Library/LaunchAgents"
rc=$(run_installer "$home4" "$stub" 0 "$work/out4")
[ "$rc" -eq 0 ]; check "945 happy path exits 0" $?
grep -q "Installed and loaded" "$work/out4"; check "945 happy path banner printed" $?
grep -qF "<string>$home4/nix/patch-vscode-insiders.sh</string>" "$home4/$PLIST_REL" 2>/dev/null
check "1366 happy path plist names the checked patch script" $?
# Byte-identical to the missing-dir run once each fixture HOME prefix
# is normalised out (#1366: the plist now derives its program path from
# $PATCH_SCRIPT, so the two fixture homes legitimately differ there).
sed "s|$home1|FIXTURE_HOME|g" "$work/golden.plist" > "$work/golden.norm" 2>/dev/null
sed "s|$home4|FIXTURE_HOME|g" "$home4/$PLIST_REL" > "$work/happy.norm" 2>/dev/null
cmp -s "$work/happy.norm" "$work/golden.norm"; check "945 happy path plist byte-identical (HOME-normalised)" $?

# --help: usage, exit 0, no side effects (#1177).
home5="$work/home5"
make_home "$home5"
HOME="$home5" PATH="$stub:$PATH" STUB_LOAD_RC=0 bash "$INSTALLER" --help > "$work/out5" 2>&1
rc=$?
[ "$rc" -eq 0 ]; check "1177 --help exits 0" $?
grep -q "Usage: bash ~/nix/install-vscode-patch-agent.sh" "$work/out5"; check "1177 --help prints usage" $?
[ ! -e "$home5/$PLIST_REL" ]; check "1177 --help writes no plist" $?
[ ! -e "$home5/Library/LaunchAgents" ]; check "1177 --help creates no LaunchAgents dir" $?

# unknown argument: exit 2 naming it, no side effects (#1177).
home6="$work/home6"
make_home "$home6"
HOME="$home6" PATH="$stub:$PATH" STUB_LOAD_RC=0 bash "$INSTALLER" --bogus > "$work/out6" 2> "$work/err6"
rc=$?
[ "$rc" -eq 2 ]; check "1177 unknown argument exits 2" $?
grep -q -- "--bogus" "$work/err6"; check "1177 unknown argument named on stderr" $?
grep -q "Usage: bash ~/nix/install-vscode-patch-agent.sh" "$work/err6"; check "1177 unknown argument prints usage on stderr" $?
[ ! -e "$home6/$PLIST_REL" ]; check "1177 unknown argument writes no plist" $?
grep -q "Installed and loaded" "$work/out6"; [ $? -ne 0 ]; check "1177 unknown argument prints no success banner" $?

# --- #2151: a failed update must preserve the loaded agent -----------
#
# Recording launchctl stub: appends "verb path" to $STUB_CALLS_LOG.
# A load fails (42) when the plist it is asked to load contains
# $STUB_LOAD_FAIL_MARKER (when set); any other load exits
# ${STUB_LOAD_RC:-0}. Unload always succeeds.
make_recording_stub() { # $1 = stub bin dir
  mkdir -p "$1"
  cat > "$1/launchctl" <<'STUB'
#!/bin/sh
if [ -n "${STUB_CALLS_LOG:-}" ]; then
  echo "$1 $2" >> "$STUB_CALLS_LOG"
fi
if [ "$1" = "load" ]; then
  if [ -n "${STUB_LOAD_FAIL_MARKER:-}" ] && grep -q "$STUB_LOAD_FAIL_MARKER" "$2" 2>/dev/null; then
    exit 42
  fi
  exit "${STUB_LOAD_RC:-0}"
fi
exit 0
STUB
  chmod +x "$1/launchctl"
}

# An "old" plist whose content is distinguishable from anything the
# installer writes (in particular it lacks the new plist's WatchPaths
# entries, which the load-failure scenario keys on).
write_old_plist() { # $1 = home dir
  mkdir -p "$1/Library/LaunchAgents"
  printf 'PREVIOUS-GOOD-PLIST for %s\n' "$1" > "$1/$PLIST_REL"
}

# failed prep: existing plist, mkdir stubbed to fail. The installer
# must exit non-zero before any unload: the old agent keeps running,
# its plist is untouched, and no success banner is printed.
stub7="$work/bin7"
make_recording_stub "$stub7"
printf '#!/bin/sh\nexit 1\n' > "$stub7/mkdir"
chmod +x "$stub7/mkdir"
home7="$work/home7"
make_home "$home7"
write_old_plist "$home7"
cp "$home7/$PLIST_REL" "$work/old7.plist"
HOME="$home7" PATH="$stub7:$PATH" STUB_CALLS_LOG="$work/calls7" bash "$INSTALLER" > "$work/out7" 2>&1
rc=$?
[ "$rc" -ne 0 ]; check "2151 failed prep exits non-zero" $?
grep -q "ERROR" "$work/out7"; check "2151 failed prep reports an error" $?
grep -q "Installed and loaded" "$work/out7"; [ $? -ne 0 ]; check "2151 failed prep prints no success banner" $?
grep -q "^unload " "$work/calls7" 2>/dev/null; [ $? -ne 0 ]; check "2151 failed prep never unloads the old agent" $?
grep -q "^load " "$work/calls7" 2>/dev/null; [ $? -ne 0 ]; check "2151 failed prep never loads" $?
cmp -s "$home7/$PLIST_REL" "$work/old7.plist"; check "2151 failed prep leaves the old plist untouched" $?

# failed load: existing plist; the stub load fails only for a plist
# containing the new plist's WatchPaths marker, so the rollback load
# of the restored previous plist succeeds. Assert the restore: exit
# non-zero, both failures named, previous plist back on disk, and the
# call log shows unload + two loads (new, then restored).
stub8="$work/bin8"
make_recording_stub "$stub8"
home8="$work/home8"
make_home "$home8"
write_old_plist "$home8"
cp "$home8/$PLIST_REL" "$work/old8.plist"
HOME="$home8" PATH="$stub8:$PATH" STUB_CALLS_LOG="$work/calls8" STUB_LOAD_FAIL_MARKER="workbench.desktop.main.js" bash "$INSTALLER" > "$work/out8" 2>&1
rc=$?
[ "$rc" -ne 0 ]; check "2151 failed load exits non-zero" $?
grep -q "launchctl load failed" "$work/out8"; check "2151 failed load names the primary failure" $?
grep -q "Restored and reloaded the previous agent" "$work/out8"; check "2151 failed load reports the rollback" $?
grep -q "Installed and loaded" "$work/out8"; [ $? -ne 0 ]; check "2151 failed load prints no success banner" $?
cmp -s "$home8/$PLIST_REL" "$work/old8.plist"; check "2151 failed load restores the previous plist" $?
[ "$(grep -c '^load ' "$work/calls8")" -eq 2 ]; check "2151 failed load loads new then restored plist" $?
grep -q "^unload " "$work/calls8"; check "2151 failed load unloaded only after staging" $?

# failed swap: existing plist, mv stubbed to fail. The staged plist
# never lands, so the previous plist stays in place and the installer
# reloads the agent it unloaded.
stub9="$work/bin9"
make_recording_stub "$stub9"
printf '#!/bin/sh\nexit 1\n' > "$stub9/mv"
chmod +x "$stub9/mv"
home9="$work/home9"
make_home "$home9"
write_old_plist "$home9"
cp "$home9/$PLIST_REL" "$work/old9.plist"
HOME="$home9" PATH="$stub9:$PATH" STUB_CALLS_LOG="$work/calls9" bash "$INSTALLER" > "$work/out9" 2>&1
rc=$?
[ "$rc" -ne 0 ]; check "2151 failed swap exits non-zero" $?
grep -q "Could not install the staged plist" "$work/out9"; check "2151 failed swap names the swap failure" $?
grep -q "Previous agent reloaded" "$work/out9"; check "2151 failed swap reports the reload" $?
grep -q "Installed and loaded" "$work/out9"; [ $? -ne 0 ]; check "2151 failed swap prints no success banner" $?
cmp -s "$home9/$PLIST_REL" "$work/old9.plist"; check "2151 failed swap leaves the previous plist in place" $?
grep -q "^load " "$work/calls9"; check "2151 failed swap reloads the old agent" $?

if [ "$failures" -gt 0 ]; then
  echo "FAILURES: $failures"
  exit 1
fi
echo "ALL PASS"
