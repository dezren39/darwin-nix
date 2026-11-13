#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Guard for the Chromium-family CDP launcher port claims (#1878).
#
# Oracle (target Mac): launching each advertised launcher yields a
# listening CDP endpoint on its advertised port, or the claim is
# removed. This guard pins the static preconditions the measured
# behaviour requires, by running the REAL `make_cdp_app` generation
# out of systemPackages.nix and asserting on the generated launchers:
#
# - Google Chrome (19223) and Microsoft Edge (19228) refuse
#   --remote-debugging-port on their default user-data-dir (measured,
#   systemPackages.nix caveat), so BOTH generated forms (.app and CLI)
#   must carry a non-default --user-data-dir; a launcher without one
#   advertises a port it cannot serve.
# - Helium (19222) serves its port on the default profile (measured),
#   so its launchers must NOT gain a profile dir that would silently
#   change which session the port serves.
# - helium-live's --browserUrl port in mcpx.config.nix equals the
#   helium-cdp launcher's port, and neither mcpx.config.nix nor
#   docs/mcp.md may claim the Local State toggle serves that port:
#   the toggle serves the approval-gated CDP server on 9222 for normal
#   launches (browser-remote-debug.py header).
#
# If make_cdp_app moves or changes shape, the extraction below fails
# loudly rather than passing vacuously.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
packages="$script_dir/systemPackages.nix"
mcpx="$script_dir/mcpx.config.nix"
docs="$script_dir/docs/mcp.md"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/chromium-family-cdp-test.XXXXXX")
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

contains() { grep -Fq -- "$1" "$2"; }
lacks() { ! grep -Fq -- "$1" "$2"; }

# --- Run the real generation -------------------------------------------
# Extract the make_cdp_app function and its invocations from the
# installPhase, de-dent them out of the nix string, and evaluate with
# $out pointed at a scratch dir. The nix antiquotation escape ''${ in
# the source is a literal ${ by the time bash sees the installPhase,
# so translate it back before evaluating.
sed -n '/^      make_cdp_app() {/,/^      }$/p' "$packages" | sed 's/^      //' | sed "s/''\${/\${/g" >"$tmp/gen.sh"
grep '^      make_cdp_app "' "$packages" | sed 's/^      //' >>"$tmp/gen.sh"
grep -q 'make_cdp_app() {' "$tmp/gen.sh" || {
  echo "FAIL: could not extract make_cdp_app from systemPackages.nix" >&2
  exit 1
}
grep -c 'make_cdp_app "' "$tmp/gen.sh" | grep -qx 3 || {
  echo "FAIL: expected exactly 3 make_cdp_app invocations in systemPackages.nix" >&2
  exit 1
}
out="$tmp/out"
# The installPhase's own first step, which the extraction above omits.
mkdir -p "$out/bin"
# shellcheck disable=SC1091
. "$tmp/gen.sh"

app_launcher() { printf '%s' "$out/Applications/$1.app/Contents/MacOS/$1"; }
cli_launcher() { printf '%s' "$out/bin/$1"; }

for form in app cli; do
  if [ "$form" = app ]; then
    chrome=$(app_launcher "Google Chrome CDP")
    edge=$(app_launcher "Microsoft Edge CDP")
    helium=$(app_launcher "Helium CDP")
  else
    chrome=$(cli_launcher google-chrome-cdp)
    edge=$(cli_launcher microsoft-edge-cdp)
    helium=$(cli_launcher helium-cdp)
  fi
  check "$form: chrome launcher exists and is executable" test -x "$chrome"
  check "$form: chrome serves 19223" contains "--remote-debugging-port=19223" "$chrome"
  check "$form: chrome supplies a non-default user-data-dir" contains '--user-data-dir=$HOME/.local/share/cdp-profiles/google-chrome' "$chrome"
  check "$form: edge launcher exists and is executable" test -x "$edge"
  check "$form: edge serves 19228" contains "--remote-debugging-port=19228" "$edge"
  check "$form: edge supplies a non-default user-data-dir" contains '--user-data-dir=$HOME/.local/share/cdp-profiles/microsoft-edge' "$edge"
  check "$form: helium launcher exists and is executable" test -x "$helium"
  check "$form: helium serves 19222" contains "--remote-debugging-port=19222" "$helium"
  check "$form: helium keeps the default profile (no user-data-dir)" lacks "--user-data-dir" "$helium"
  check "$form: all launchers bind loopback only" contains "--remote-debugging-address=127.0.0.1" "$chrome"
done

# --- Cross-file port agreement ------------------------------------------
check "mcpx helium-live targets the helium-cdp port 19222" \
  contains '--browserUrl=http://127.0.0.1:19222' "$mcpx"
check "mcpx no longer claims the Local State toggle serves 19222" \
  lacks 'or Helium with Local State remote debugging enabled' "$mcpx"
grep '^| helium-live' "$docs" >"$tmp/helium-row.txt"
check "docs helium-live row names the helium-cdp launcher for 19222" \
  contains 'helium-cdp' "$tmp/helium-row.txt"
check "docs helium-live row does not claim the Local State toggle serves 19222" \
  lacks '(`helium-cdp` or `Local State` toggle)' "$tmp/helium-row.txt"

if [ "$failures" -gt 0 ]; then
  echo "$failures chromium-family-cdp guard check(s) failed" >&2
  exit 1
fi
echo "chromium-family-cdp guard: all checks passed"
