#!/usr/bin/env bash
# Regression test for simple-rebuild.sh's phase_build staleness guard (#2030).
#
# A zero-exit `nix build` that leaves a pre-existing ./result unchanged used
# to pass the shape check (./result/sw/bin/darwin-rebuild exists), so the
# prior system was recorded as a fresh build and could be activated. phase_build
# now removes ./result before the build, so a ./result present after a zero-exit
# build must have been produced by that invocation.
#
# Like simple-rebuild.test.sh this extracts the REAL phase_build function from
# simple-rebuild.sh, so the test follows the shipped code. nix, hostname and the
# commit/print helpers are stubbed.
#
# Run: ./simple-rebuild-phase-build.test.sh
# It is run by the flake check `simple-rebuild-phase-build-tests`.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/simple-rebuild.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $1"; }

FUNC="$TMP_ROOT/phase_build.bash"
awk '/^phase_build\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$SCRIPT" >"$FUNC"
[ -s "$FUNC" ] || { echo "could not extract phase_build from simple-rebuild.sh" >&2; exit 1; }

# Runs phase_build in a fresh directory. $1 = dir, $2 = nix stub body.
# Sets STATUS and MARKERS (commit_marker calls, one per line).
run_phase() {
  local dir="$1" nix_body="$2"
  local probe="$TMP_ROOT/probe.sh" markers="$TMP_ROOT/markers"
  : >"$markers"
  cat >"$probe" <<EOF
#!/usr/bin/env bash
source "$FUNC"
hostname() { echo testhost; }
print_error() { echo "\$*" >&2; }
commit_marker() { echo "\$1" >>"$markers"; }
nix() { $nix_body; }
cd "$dir" && phase_build
EOF
  USER=tester bash "$probe" >/dev/null 2>"$TMP_ROOT/err"; STATUS=$?
  MARKERS="$(cat "$markers")"
}

new_dir() { mktemp -d "$TMP_ROOT/dir.XXXXXX"; }

# A valid earlier build that the new run does not refresh.
dir="$(new_dir)"
mkdir -p "$TMP_ROOT/store/old-sys/sw/bin"
: >"$TMP_ROOT/store/old-sys/sw/bin/darwin-rebuild"
chmod +x "$TMP_ROOT/store/old-sys/sw/bin/darwin-rebuild"
ln -s "$TMP_ROOT/store/old-sys" "$dir/result"
run_phase "$dir" 'return 0'
if [ "$STATUS" -ne 0 ] && [ -z "$MARKERS" ]; then
  ok "zero-exit build that leaves a stale ./result is rejected, no marker committed"
else
  fail "stale ./result accepted: status=$STATUS markers=[$MARKERS]"
fi

# No ./result at all after a zero-exit build.
dir="$(new_dir)"
run_phase "$dir" 'return 0'
if [ "$STATUS" -ne 0 ] && [ -z "$MARKERS" ]; then
  ok "zero-exit build with no ./result is rejected"
else
  fail "absent ./result accepted: status=$STATUS markers=[$MARKERS]"
fi

# A build that writes its own ./result is accepted and records its store path.
dir="$(new_dir)"
ln -s "$TMP_ROOT/store/old-sys" "$dir/result"
run_phase "$dir" 'mkdir -p ./new-sys/sw/bin && : >./new-sys/sw/bin/darwin-rebuild && chmod +x ./new-sys/sw/bin/darwin-rebuild && ln -sfn "$PWD/new-sys" ./result'
case "$MARKERS" in
  *"testhost build new-sys"*) ok "fresh ./result from this build is accepted and recorded" ;;
  *) fail "fresh build not recorded (status=$STATUS markers=[$MARKERS])" ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "$failures simple-rebuild phase_build check(s) failed" >&2
  exit 1
fi
echo "all simple-rebuild phase_build checks passed"
