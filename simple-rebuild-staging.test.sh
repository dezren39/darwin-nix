#!/usr/bin/env bash
# Regression test for simple-rebuild.sh's scoped staging (#1864).
#
# simple-rebuild.sh ran `git add .` at startup and again in
# record_activation: every valid run staged the whole worktree --
# unrelated tracked edits and untracked files alike -- and the marker
# commits could silently swallow work that was never part of the
# rebuild. rebuild-staging.test.sh (#1852) covers only the outer
# rebuild.sh, whose stub replaces this script, so this path was
# uncovered.
#
# The fix registers NEW flake inputs only: an untracked, non-ignored
# file whose path (or an ancestor directory) is mentioned by a
# tracked file is registered with intent-to-add -- the flake reads
# its real worktree content, no content is staged -- and the
# registration is removed before any commit and at exit. Tracked
# edits are never staged (the flake reads them from the worktree).
#
# This suite drives the REAL simple-rebuild.sh in a disposable git
# repo, in --build-only mode, for normal and --no-commit runs. The
# only change to the fixture copy is the #1852-precedent redirection
# of the external `nix build` invocation to a stub; the stub proves
# with the REAL nix that the flake can see and read the new inputs at
# build time, then fakes ./result so phase_build can finish. The
# token refresh's `gh auth token` is stubbed to "logged out" (its
# other external effect); everything else is inert in the fixture
# (no root-owned files, no Xcode on the probe paths).
#
# Run: bash simple-rebuild-staging.test.sh (exit 0 = all passed)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/simple-rebuild.sh"

command -v zsh >/dev/null || { echo "zsh required" >&2; exit 1; }
command -v git >/dev/null || { echo "git required" >&2; exit 1; }
command -v nix >/dev/null || { echo "nix required" >&2; exit 1; }
REAL_NIX="$(command -v nix)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
check() { # $1 name, $2 condition-result (0 = pass)
  if [ "$2" -eq 0 ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    failures=$((failures + 1))
  fi
}

# --- Static pins: both staging sites use the scoped helper ---------
grep -q '^stage_flake_inputs() {' "$SCRIPT"; check "1864 staging helper is defined" $?
[ "$(grep -c '^  stage_flake_inputs$' "$SCRIPT")" -ge 1 ]; check "1864 startup site calls stage_flake_inputs" $?
awk '/^record_activation\(\) \{/,/^\}/' "$SCRIPT" | grep -q 'stage_flake_inputs'
check "1864 record_activation calls stage_flake_inputs" $?
awk '/^record_activation\(\) \{/,/^\}/' "$SCRIPT" | grep -q 'git add'; [ $? -ne 0 ]
check "1864 record_activation contains no git add" $?
grep -E '^[[:space:]]*git add \.' "$SCRIPT" >/dev/null; [ $? -ne 0 ]
check "1864 no executable 'git add .' remains in simple-rebuild.sh" $?

make_fixture() { # $1 = fixture dir
  local fx="$1"
  mkdir -p "$fx/bin" "$fx/home" "$fx/fake-system/sw/bin" "$fx/vendor"
  cp "$SCRIPT" "$fx/simple-rebuild.sh"
  chmod +x "$fx/simple-rebuild.sh"
  # Redirect ONLY the external nix build invocation to the stub
  # (the rebuild-staging.test.sh precedent); fail loudly if the
  # invocation shape changes and the redirect no longer applies.
  sed -i "s|^  nix --extra-experimental-features 'nix-command flakes' \\\\$|  \"$fx/bin/nix\" --extra-experimental-features 'nix-command flakes' \\\\|" "$fx/simple-rebuild.sh"
  grep -q "\"$fx/bin/nix\" --extra-experimental-features" "$fx/simple-rebuild.sh"
  check "fixture: nix build invocation redirected to the stub" $?

  cat > "$fx/bin/nix" <<'EOF'
#!/usr/bin/env bash
# Stub for `nix build`: prove with the real nix that the flake can
# see and read BOTH new inputs at build time (an unregistered file
# makes the eval fail), then fake the build result.
set -euo pipefail
got="$("$SR_TEST_REAL_NIX" eval --json --extra-experimental-features 'nix-command flakes' .#inp)"
[ "$got" = '"brand new input\n"' ] || { echo "stub nix: flake did not see new-input.txt (got: $got)" >&2; exit 1; }
got2="$("$SR_TEST_REAL_NIX" eval --json --extra-experimental-features 'nix-command flakes' .#inp2)"
[ "$got2" = '"pkg input\n"' ] || { echo "stub nix: flake did not see vendor/newpkg/default.nix (got: $got2)" >&2; exit 1; }
printf '#!/bin/sh\nexit 0\n' > "$SR_TEST_FAKE_SYSTEM/sw/bin/darwin-rebuild"
chmod +x "$SR_TEST_FAKE_SYSTEM/sw/bin/darwin-rebuild"
ln -sfn "$SR_TEST_FAKE_SYSTEM" ./result
printf 'built\n' >> "$SR_TEST_MARKER"
EOF
  # The build sandbox has no /usr/bin/env: point the stub's shebang
  # at the same bash that is running this suite.
  sed -i "1s|^#!/usr/bin/env bash\$|#!$(command -v bash)|" "$fx/bin/nix"
  chmod +x "$fx/bin/nix"

  # gh stub: refresh_nix_access_token's `gh auth token` must take its
  # logged-out path (it only rewrites a file outside the repo when a
  # token exists; the staging assertions do not depend on it).
  printf '#!%s\nexit 1\n' "$(command -v bash)" > "$fx/bin/gh"
  chmod +x "$fx/bin/gh"

  # hostname stub: phase_build names the build with $(hostname -s)
  # and $(hostname); a bare sandbox PATH may have no hostname at all,
  # and the value itself is irrelevant to the staging assertions.
  printf '#!%s\necho testhost\n' "$(command -v bash)" > "$fx/bin/hostname"
  chmod +x "$fx/bin/hostname"

  # flake.nix references the two new inputs: one by full path, one by
  # its package directory only (the ancestor-directory rule).
  cat > "$fx/flake.nix" <<'EOF'
{ outputs = { self }: {
    inp = builtins.readFile (self + "/new-input.txt");
    inp2 = builtins.readFile (self + "/vendor/newpkg" + "/default.nix");
  }; }
EOF
  printf 'tracked base\n' > "$fx/tracked.txt"
  git -C "$fx" init -q
  git -C "$fx" config user.name test
  git -C "$fx" config user.email test@example.invalid
  git -C "$fx" add flake.nix tracked.txt
  git -C "$fx" commit -qm initial

  # The worktree state a valid run must not sweep up:
  printf 'unrelated edit\n' >> "$fx/tracked.txt"        # unrelated tracked edit
  printf '# unrelated flake edit\n' >> "$fx/flake.nix"  # tracked edit (also unstaged)
  printf 'brand new input\n' > "$fx/new-input.txt"      # new input, referenced by path
  mkdir -p "$fx/vendor/newpkg"
  printf 'pkg input\n' > "$fx/vendor/newpkg/default.nix" # new input, referenced by directory
  printf 'unrelated untracked\n' > "$fx/notes.txt"      # unrelated untracked file
}

assert_unstaged() { # $1 = fixture dir, $2 = label prefix
  local fx="$1" label="$2" st
  git -C "$fx" diff --cached --quiet; check "$label: nothing is staged after the run" $?
  st="$(git -C "$fx" status --porcelain)"
  printf '%s\n' "$st" | grep -q '^ M tracked.txt$'; check "$label: unrelated tracked edit remains unstaged" $?
  printf '%s\n' "$st" | grep -q '^ M flake.nix$'; check "$label: tracked flake.nix edit remains unstaged" $?
  printf '%s\n' "$st" | grep -q '^?? notes.txt$'; check "$label: unrelated untracked file remains untracked" $?
  printf '%s\n' "$st" | grep -q '^?? new-input.txt$'; check "$label: new input is untracked again after the run (registration removed)" $?
  printf '%s\n' "$st" | grep -q '^?? vendor/$'; check "$label: new package dir is untracked again after the run" $?
  printf '%s\n' "$st" | grep -q '^A'; [ $? -ne 0 ]; check "$label: no added entries in the index" $?
}

run_scenario() { # $1 = name, $2 = fixture dir, $3... = script args
  local name="$1" fx="$2"; shift 2
  make_fixture "$fx"
  local before after
  before="$(git -C "$fx" rev-list --count HEAD)"
  ( cd "$fx" && HOME="$fx/home" PATH="$fx/bin:$PATH" USER="${USER:-$(id -un)}" \
      SR_TEST_REAL_NIX="$REAL_NIX" SR_TEST_FAKE_SYSTEM="$fx/fake-system" \
      SR_TEST_MARKER="$fx/stub-marker" \
      zsh "$fx/simple-rebuild.sh" "$@" > "$fx/run.log" 2>&1 )
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "--- $name run.log (last 30 lines) ---" >&2
    tail -30 "$fx/run.log" >&2
    echo "--- end run.log ---" >&2
  fi
  check "$name: real script exits 0 (stubbed build)" "$rc"
  [ -f "$fx/stub-marker" ]; check "$name: stubbed nix build ran (flake saw both new inputs)" $?
  grep -q 'registered 2 new flake input(s)' "$fx/run.log"
  check "$name: exactly the 2 referenced new inputs were registered" $?
  assert_unstaged "$fx" "$name"
  after="$(git -C "$fx" rev-list --count HEAD)"
  if [ "$name" = "normal" ]; then
    [ "$after" -eq $((before + 1)) ]; check "$name: exactly one marker commit was made" $?
    [ -z "$(git -C "$fx" diff HEAD~1 HEAD --name-only)" ]
    check "$name: marker commit captured no files" $?
  else
    [ "$after" -eq "$before" ]; check "$name: --no-commit made no marker commit" $?
  fi
}

run_scenario normal "$work/fx-normal" --build-only
run_scenario no-commit "$work/fx-nocommit" --build-only --no-commit

if [ "$failures" -gt 0 ]; then
  echo "FAILURES: $failures"
  exit 1
fi
echo "ALL PASS"
