#!/usr/bin/env bash
# Tests for brew-adopt-unmanaged.sh (#1791). Every external command the
# script touches is stubbed: stat/chown via PATH, sudo/brew/PlistBuddy
# via the script's BREW_ADOPT_* overrides. State lives in $STUB_STATE:
#   chrome_owner          — what the stat stub reports for Chrome.app
#   receipt_<name>        — presence = `brew list --cask <name>` succeeds
#   calls                 — one line per stub invocation
# FAIL_CHOWN / FAIL_ADOPT / FAIL_FORCE make the matching stub exit 1.
# OD_CFVERSION / OD_CFSHORT are what the PlistBuddy stub prints.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$script_dir/brew-adopt-unmanaged.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/brew-adopt-unmanaged-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/state" "$tmp/apps" \
  "$tmp/taps/dezren39/homebrew-local/Casks" "$tmp/taps/homebrew/homebrew-cask/Casks/o"

cat >"$tmp/taps/dezren39/homebrew-local/Casks/onedrive.rb" <<'RB'
cask "onedrive" do
  version "26.198.1011.0006"
end
RB
cat >"$tmp/taps/homebrew/homebrew-cask/Casks/o/onedrive.rb" <<'RB'
cask "onedrive" do
  version "26.189.0928.0009"
end
RB

# Stub shebangs use the build env's bash by absolute path: /usr/bin/env
# does not exist inside the nix build sandbox (same pattern as
# system-activation-helper.test.sh).
stub() {
  printf '#!%s\n' "$(command -v bash)" >"$tmp/bin/$1"
  cat >>"$tmp/bin/$1"
}

stub stat <<'STUB'
echo "stat $*" >>"$STUB_STATE/calls"
cat "$STUB_STATE/chrome_owner"
STUB

stub chown <<'STUB'
echo "chown $*" >>"$STUB_STATE/calls"
if [ "${FAIL_CHOWN:-0}" = 1 ]; then exit 1; fi
# chown -R USER PATH — record USER as the new owner.
echo "$2" >"$STUB_STATE/chrome_owner"
STUB

stub sudo <<'STUB'
# sudo --user=USER --set-home CMD... → run CMD directly.
shift 2
exec "$@"
STUB

stub brew <<'STUB'
echo "brew $*" >>"$STUB_STATE/calls"
case "$1" in
  list)
    name=${3//\//_}
    [ -e "$STUB_STATE/receipt_$name" ]
    ;;
  install)
    if [ "$3" = "--adopt" ]; then
      [ "${FAIL_ADOPT:-0}" = 1 ] && exit 1
    else
      [ "${FAIL_FORCE:-0}" = 1 ] && exit 1
    fi
    touch "$STUB_STATE/receipt_${4//\//_}"
    ;;
esac
STUB

stub plistbuddy <<'STUB'
case "$2" in
  *CFBundleShortVersionString*) [ -n "${OD_CFSHORT:-}" ] && echo "$OD_CFSHORT" || exit 1 ;;
  *CFBundleVersion*) [ -n "${OD_CFVERSION:-}" ] && echo "$OD_CFVERSION" || exit 1 ;;
esac
STUB

chmod +x "$tmp/bin/"*

failures=0
check() {
  local name=$1
  shift
  if "$@"; then
    echo "ok: $name"
  else
    echo "FAIL: $name" >&2
    failures=$((failures + 1))
  fi
}

reset_state() {
  rm -f "$tmp/state/"*
  mkdir -p "$tmp/apps/Google Chrome.app" "$tmp/apps/OneDrive.app"
  echo root >"$tmp/state/chrome_owner"
  FAIL_CHOWN=0 FAIL_ADOPT=0 FAIL_FORCE=0
  OD_CFVERSION="26.198.1011.0006" OD_CFSHORT="26.198.1011"
  UPSTREAM_VERSION="26.189.0928.0009"
}

# BREW_ADOPT_PATH puts the stub bin first and keeps the ambient PATH
# behind it: the /usr/bin:/bin of a nix build sandbox are not the
# host's (#1099), so the script must still find the build env's
# env/sed/head there — the same tools it finds in /usr/bin on a Mac.
run_script() {
  cat >"$tmp/taps/homebrew/homebrew-cask/Casks/o/onedrive.rb" <<RB
cask "onedrive" do
  version "$UPSTREAM_VERSION"
end
RB
  STUB_STATE="$tmp/state" \
    BREW_ADOPT_PATH="$tmp/bin:$PATH" \
    BREW_ADOPT_BREW="$tmp/bin/brew" \
    BREW_ADOPT_SUDO="$tmp/bin/sudo" \
    BREW_ADOPT_PLISTBUDDY="$tmp/bin/plistbuddy" \
    BREW_ADOPT_APPLICATIONS="$tmp/apps" \
    BREW_ADOPT_TAPS_DIR="$tmp/taps" \
    FAIL_CHOWN=$FAIL_CHOWN FAIL_ADOPT=$FAIL_ADOPT FAIL_FORCE=$FAIL_FORCE \
    OD_CFVERSION="$OD_CFVERSION" OD_CFSHORT="$OD_CFSHORT" \
    bash "$script" drewry.pope >"$tmp/out" 2>&1
}

# run: like run_script but never aborts the harness under `set -e`;
# the script's exit code lands in $rc for the checks. Output is also
# appended to $tmp/all-out, dumped at the end when any check failed —
# in the nix sandbox the build log is otherwise the only evidence.
run() {
  rc=0
  run_script || rc=$?
  {
    echo "--- run (rc=$rc) ---"
    cat "$tmp/out"
  } >>"$tmp/all-out"
}

calls_has() { grep -q "$1" "$tmp/state/calls"; }
out_has() {
  if [ "$1" = "-v" ]; then
    ! grep -q "$2" "$tmp/out"
  else
    grep -q "$1" "$tmp/out"
  fi
}

# 1. Root-owned Chrome, no receipt: chown, then --adopt, receipt lands.
reset_state
run
check "root-owned chrome: exit 0" test $rc -eq 0
check "root-owned chrome: chown called" calls_has "chown -R drewry.pope"
check "root-owned chrome: adopt called" calls_has "brew install --cask --adopt google-chrome"
check "root-owned chrome: receipt written" test -e "$tmp/state/receipt_google-chrome"

# 2. Root-owned Chrome, chown fails: exit 1 before any brew call.
reset_state
FAIL_CHOWN=1
run
check "chown fails: exit 1" test $rc -eq 1
check "chown fails: no brew call" out_has -v "brew install"
check "chown fails: remedy printed" out_has "sudo chown -R drewry.pope"

# 3. User-owned Chrome with receipt: complete no-op.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome" "$tmp/state/receipt_dezren39_local_onedrive"
run
check "managed chrome: exit 0" test $rc -eq 0
check "managed chrome: no chown" out_has -v "chown -R"
check "managed chrome: nothing to adopt logged" out_has "already brew-managed"

# 4. --adopt fails, --force succeeds: both attempted, exit 0.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
FAIL_ADOPT=1
run
check "adopt fails: exit 0 via force fallback" test $rc -eq 0
check "adopt fails: force attempted" calls_has "brew install --cask --force google-chrome"
check "adopt fails: receipt written" test -e "$tmp/state/receipt_google-chrome"

# 5. OneDrive at exactly the vendored version, no receipt: proceed, exit 0.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome"
run
check "onedrive current: exit 0" test $rc -eq 0
check "onedrive current: bundle handoff logged" out_has "brew bundle will install the vendored pkg"

# 6. OneDrive self-updated past the vendored version, no receipt: exit 1.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome"
OD_CFVERSION="26.204.1019.0004"
run
check "onedrive raced: exit 1" test $rc -eq 1
check "onedrive raced: remedy printed" out_has "bump homebrew-local/Casks/onedrive.rb to 26.204.1019.0004"

# 7. OneDrive receipt present: newer app version is no longer a problem.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome" "$tmp/state/receipt_dezren39_local_onedrive"
OD_CFVERSION="26.204.1019.0004"
run
check "onedrive managed: exit 0 despite newer app" test $rc -eq 0
check "onedrive managed: nothing to do logged" out_has "already brew-managed via the vendored cask"

# 8. Upstream cask caught up: retirement tripwire logs, exit stays 0.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome" "$tmp/state/receipt_dezren39_local_onedrive"
UPSTREAM_VERSION="26.198.1011.0006"
run
check "upstream caught up: exit 0" test $rc -eq 0
check "upstream caught up: retire logged" out_has "retire homebrew-local"

# 9. OneDrive present but both PlistBuddy reads fail: fail closed, exit 1.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome"
OD_CFVERSION=""
OD_CFSHORT=""
run
check "onedrive unreadable: exit 1" test $rc -eq 1
check "onedrive unreadable: diagnostic names the plist" out_has "could not be read"
check "onedrive unreadable: plist path named" out_has "OneDrive.app/Contents/Info.plist"
check "onedrive unreadable: no bundle handoff logged" out_has -v "brew bundle will install the vendored pkg"

# 10. No apps at all (fresh machine): both skip cleanly.
reset_state
rm -rf "$tmp/apps/Google Chrome.app" "$tmp/apps/OneDrive.app"
run
check "fresh machine: exit 0" test $rc -eq 0
check "fresh machine: chrome fresh-install note" out_has "brew bundle will install it fresh"
check "fresh machine: onedrive fresh-install note" out_has "brew bundle will install the vendored cask fresh"

if [ $failures -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  echo "--- captured script output ---" >&2
  cat "$tmp/all-out" >&2
  exit 1
fi
echo "all checks passed"
