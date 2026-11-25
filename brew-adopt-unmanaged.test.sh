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

# STAT_DIALECT picks which stat the stub imitates. bsd is macOS's
# /usr/bin/stat; gnu is coreutils' stat, which comes first on PATH during
# darwin activation and reads `-f` as --file-system, printing filesystem
# info and failing on the %Su format (switch-20261116T052331.log).
stub stat <<'STUB'
echo "stat $*" >>"$STUB_STATE/calls"
case "${STAT_DIALECT:-bsd}:$1" in
  bsd:-f | gnu:-c) cat "$STUB_STATE/chrome_owner" ;;
  bsd:-c) echo "stat: illegal option -- c" >&2; exit 1 ;;
  gnu:-f) echo "  File: \"$3\""; echo "stat: cannot read file system information for '%Su': No such file or directory" >&2; exit 1 ;;
  *) echo "stat stub: unexpected $*" >&2; exit 2 ;;
esac
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
  STAT_DIALECT=bsd
  OD_CFVERSION="26.198.1011.0006" OD_CFSHORT="26.198.1011"
  UPSTREAM_VERSION="26.189.0928.0009"
  # Test 10 deletes and then empties the vendored cask; restore it so
  # every later case starts from the same fixture.
  cat >"$tmp/taps/dezren39/homebrew-local/Casks/onedrive.rb" <<'RB'
cask "onedrive" do
  version "26.198.1011.0006"
end
RB
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
    STAT_DIALECT=$STAT_DIALECT \
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

# run_args: like run but with explicit arguments instead of the fixed
# primary user, for the argument-contract scenarios (#1884).
run_args() {
  rc=0
  STUB_STATE="$tmp/state" \
    BREW_ADOPT_PATH="$tmp/bin:$PATH" \
    BREW_ADOPT_BREW="$tmp/bin/brew" \
    BREW_ADOPT_SUDO="$tmp/bin/sudo" \
    BREW_ADOPT_PLISTBUDDY="$tmp/bin/plistbuddy" \
    BREW_ADOPT_APPLICATIONS="$tmp/apps" \
    BREW_ADOPT_TAPS_DIR="$tmp/taps" \
    bash "$script" "$@" >"$tmp/out" 2>&1 || rc=$?
  {
    echo "--- run_args $* (rc=$rc) ---"
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

# 10. OneDrive present, installed version known, but the vendored cask
# version is unreadable: fail closed (#1899, distinct from test 9's
# installed-version-unknown). Two shapes: file missing, and file present
# with no version stanza.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome"
rm "$tmp/taps/dezren39/homebrew-local/Casks/onedrive.rb"
run
check "onedrive vendored missing: exit 1" test $rc -eq 1
check "onedrive vendored missing: diagnostic names the vendored file" out_has "vendored cask version could not be read"
check "onedrive vendored missing: remedy printed" out_has "restore or fix homebrew-local/Casks/onedrive.rb"
check "onedrive vendored missing: no bundle handoff logged" out_has -v "brew bundle will install the vendored pkg"

reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome"
cat >"$tmp/taps/dezren39/homebrew-local/Casks/onedrive.rb" <<'RB'
cask "onedrive" do
end
RB
run
check "onedrive vendored unparsable: exit 1" test $rc -eq 1
check "onedrive vendored unparsable: diagnostic names the vendored file" out_has "vendored cask version could not be read"
check "onedrive vendored unparsable: no bundle handoff logged" out_has -v "brew bundle will install the vendored pkg"

# 11. No apps at all (fresh machine): both skip cleanly.
reset_state
rm -rf "$tmp/apps/Google Chrome.app" "$tmp/apps/OneDrive.app"
run
check "fresh machine: exit 0" test $rc -eq 0
check "fresh machine: chrome fresh-install note" out_has "brew bundle will install it fresh"
check "fresh machine: onedrive fresh-install note" out_has "brew bundle will install the vendored cask fresh"

# 11. Extra positional argument: usage error, exit 2, no side effects (#1884).
reset_state
run_args drewry.pope extra-arg
check "extra arg: exit 2" test $rc -eq 2
check "extra arg: names the offending argument" out_has "unexpected argument: extra-arg"
check "extra arg: usage printed" out_has "usage: brew-adopt-unmanaged.sh PRIMARY_USER"
check "extra arg: no stub calls" test ! -s "$tmp/state/calls"

# 12. No argument at all: usage error, exit 2, no side effects (#1884).
reset_state
run_args
check "no arg: exit 2" test $rc -eq 2
check "no arg: usage printed" out_has "usage: brew-adopt-unmanaged.sh PRIMARY_USER"
check "no arg: no stub calls" test ! -s "$tmp/state/calls"

# 12b. Empty-string argument: the count check alone passes, so the value
# must be rejected at the contract too — usage error, exit 2, no side
# effects (#2188; PR #1974 dropped the old ${1:?} guard).
reset_state
run_args ""
check "empty arg: exit 2" test $rc -eq 2
check "empty arg: names the problem" out_has "PRIMARY_USER must not be empty"
check "empty arg: usage printed" out_has "usage: brew-adopt-unmanaged.sh PRIMARY_USER"
check "empty arg: no stub calls" test ! -s "$tmp/state/calls"

# 13. --help and -h: usage on stdout, exit 0, no side effects (#1884).
reset_state
run_args --help
check "--help: exit 0" test $rc -eq 0
check "--help: usage printed" out_has "usage: brew-adopt-unmanaged.sh PRIMARY_USER"
check "--help: no stub calls" test ! -s "$tmp/state/calls"
reset_state
run_args -h
check "-h: exit 0" test $rc -eq 0
check "-h: usage printed" out_has "usage: brew-adopt-unmanaged.sh PRIMARY_USER"
check "-h: no stub calls" test ! -s "$tmp/state/calls"
reset_state
run_args --help extra
check "--help+extra: exit 2" test $rc -eq 2
check "--help+extra: names the offending argument" out_has "unexpected argument: extra"
check "--help+extra: usage printed" out_has "usage: brew-adopt-unmanaged.sh PRIMARY_USER"
check "--help+extra: no stub calls" test ! -s "$tmp/state/calls"

# 14. GNU stat first on PATH (as during darwin activation): the owner is
# still read correctly, so a root-owned bundle is chowned and adopted.
reset_state
STAT_DIALECT=gnu
run
check "gnu stat: exit 0" test $rc -eq 0
check "gnu stat: chown called" calls_has "chown -R drewry.pope"
check "gnu stat: owner read, not filesystem info" out_has -v "File:"
check "gnu stat: adopt called" calls_has "brew install --cask --adopt google-chrome"

# 15. GNU stat, user-owned bundle: no chown.
reset_state
STAT_DIALECT=gnu
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome" "$tmp/state/receipt_dezren39_local_onedrive"
run
check "gnu stat, managed chrome: exit 0" test $rc -eq 0
check "gnu stat, managed chrome: no chown" out_has -v "chown -R"

# 16. OneDrive 26.212 writes CFBundleVersion without the first dot
# (26212.1029.0006, short 26.212.1029). The version reported and compared
# must be 26.212.1029.0006, the form Microsoft's pkg URL uses: a newer
# install still fails closed, and the remedy names the dotted version.
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome"
OD_CFVERSION="26212.1029.0006" OD_CFSHORT="26.212.1029"
run
check "dotless build: newer still exits 1" test $rc -eq 1
check "dotless build: remedy names the dotted version" out_has "bump homebrew-local/Casks/onedrive.rb to 26.212.1029.0006"
check "dotless build: dotless form not offered" out_has -v "to 26212.1029.0006"

# 17. Same dotless build, vendored cask bumped to match: same-version
# install proceeds (comparing 26212 against 26 would call it newer).
reset_state
echo drewry.pope >"$tmp/state/chrome_owner"
touch "$tmp/state/receipt_google-chrome"
OD_CFVERSION="26212.1029.0006" OD_CFSHORT="26.212.1029"
vendored_rb="$tmp/taps/dezren39/homebrew-local/Casks/onedrive.rb"
cp "$vendored_rb" "$tmp/onedrive.rb.orig"
sed -i.bak 's/version "26.198.1011.0006"/version "26.212.1029.0006"/' "$vendored_rb"
grep -q '26.212.1029.0006' "$vendored_rb" || { echo "FAIL: test 17 setup did not bump the vendored version" >&2; exit 1; }
run
check "dotless build, matching cask: exit 0" test $rc -eq 0
check "dotless build, matching cask: bundle handoff logged" out_has "brew bundle will install the vendored pkg"
cp "$tmp/onedrive.rb.orig" "$vendored_rb"

if [ $failures -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  echo "--- captured script output ---" >&2
  cat "$tmp/all-out" >&2
  exit 1
fi
echo "all checks passed"
