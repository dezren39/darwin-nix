#!/usr/bin/env bash
# opencode-notifier-deploy.test.sh — regression test for issue #2143
# (follow-up to #2060).
#
# PR #2168 deployed opencode-notifier.json through homeUser.nix: the
# repo copy names each event's sound by bare file name, home-manager
# deploys the repo's sounds/ beside the config, and the deployed file
# is generated with the user's home directory completing the paths
# (the plugin plays the paths verbatim — no tilde or relative
# resolution). Nothing pinned that contract, so a future edit could
# silently reintroduce a hard-coded /Users/<name> path, name a sound
# that does not exist, or drop the deployment entirely.
#
# This test pins:
#   1. the repo config carries no absolute path (the #2143 acceptance
#      grep: no /Users/drewry.pope, and no sound value is a path);
#   2. every sound the config names exists in the repo's sounds/;
#   3. homeUser.nix still deploys both the config and the sounds dir,
#      reads the repo copy, and completes paths from
#      config.home.homeDirectory — with no literal /Users/ path in the
#      notifier block;
#   4. the round-trip: generating the deployed file the way
#      homeUser.nix does (home + /.config/opencode/sounds/<file>)
#      yields only absolute paths under that home whose targets exist
#      in the deployed sounds tree.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_json="$script_dir/opencode-notifier.json"
sounds_dir="$script_dir/sounds"
home_user="$script_dir/homeUser.nix"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/opencode-notifier-deploy-test.XXXXXX")
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

# --- 1. the repo config carries no absolute path -------------------------

check "config exists" test -f "$config_json"
check "config has no /Users/drewry.pope path (acceptance grep)" \
  bash -c "! grep -q '/Users/drewry.pope' '$config_json'"
check "config has no /Users/ path at all" \
  bash -c "! grep -q '/Users/' '$config_json'"

# Sound values must be bare file names: no leading slash, no slash
# anywhere, no tilde. python3 does the JSON work so a malformed file
# fails here rather than passing the greps vacuously.
sound_names="$tmp/sound-names.txt"
parse_rc=0
python3 - "$config_json" "$sound_names" <<'PYEOF' || parse_rc=$?
import json, sys
with open(sys.argv[1]) as fh:
    cfg = json.load(fh)
sounds = cfg.get("sounds")
assert isinstance(sounds, dict) and sounds, "config has no sounds map"
with open(sys.argv[2], "w") as out:
    for event, name in sorted(sounds.items()):
        assert isinstance(name, str) and name, f"{event}: empty sound name"
        assert "/" not in name, f"{event}: sound is a path, not a file name: {name}"
        assert not name.startswith("~"), f"{event}: sound starts with ~: {name}"
        out.write(name + "\n")
PYEOF
check "config parses; every sound is a bare file name" \
  bash -c "[ '$parse_rc' -eq 0 ] && [ -s '$sound_names' ]"

# --- 2. every named sound exists in sounds/ -------------------------------

missing=0
while IFS= read -r name; do
  if [ ! -f "$sounds_dir/$name" ]; then
    echo "missing sound file: sounds/$name" >&2
    missing=1
  fi
done <"$sound_names"
check "every named sound exists in sounds/" test "$missing" -eq 0

# --- 3. homeUser.nix deploys config + sounds, home-completed --------------

# Extract the notifier block: from its #2060 comment to the closing
# line of the generated-config expression (the first bare ");" line).
block="$tmp/notifier-block.txt"
awk '/opencode-notifier \(#2060\)/ { in_block = 1 }
     in_block { print }
     in_block && /^[[:space:]]*\);[[:space:]]*$/ { exit }' \
  "$home_user" >"$block"

check "notifier block extracted from homeUser.nix" test -s "$block"
check "homeUser.nix deploys the sounds dir beside the config" \
  grep -q '".config/opencode/sounds".source = ./sounds;' "$block"
check "homeUser.nix deploys the notifier config" \
  grep -q '".config/opencode/opencode-notifier.json".text' "$block"
check "deployed config is generated from the repo copy" \
  grep -q 'builtins.readFile ./opencode-notifier.json' "$block"
check "deployed paths are completed from the user's home directory" \
  grep -q 'config.home.homeDirectory' "$block"
check "notifier block has no literal /Users/ path" \
  bash -c "! grep -q '/Users/' '$block'"

# --- 4. round-trip: the generated deployed file resolves ------------------

# Mirror homeUser.nix's generation with a stand-in home, then require
# every generated sound path to live under that home's deployed
# sounds dir and to name a file the deployment actually puts there.
fake_home="/home/testuser"
roundtrip_rc=0
python3 - "$config_json" "$sounds_dir" "$fake_home" <<'PYEOF' || roundtrip_rc=$?
import json, os, sys
with open(sys.argv[1]) as fh:
    cfg = json.load(fh)
sounds_dir, fake_home = sys.argv[2], sys.argv[3]
prefix = f"{fake_home}/.config/opencode/sounds"
deployed = dict(cfg)
deployed["sounds"] = {event: f"{prefix}/{name}"
                      for event, name in cfg["sounds"].items()}
for event, path in deployed["sounds"].items():
    assert path.startswith(prefix + "/"), f"{event}: escaped the sounds dir: {path}"
    assert "/Users/" not in path, f"{event}: hard-coded user path: {path}"
    target = os.path.join(sounds_dir, os.path.basename(path))
    assert os.path.isfile(target), f"{event}: deployed target missing: {path}"
# The generated file must round-trip as JSON with no bare names left.
again = json.loads(json.dumps(deployed))
assert all("/" in p for p in again["sounds"].values())
PYEOF
check "generated deployed file resolves every sound under the home" \
  test "$roundtrip_rc" -eq 0

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all opencode-notifier deploy checks passed"
