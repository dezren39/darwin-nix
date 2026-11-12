#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fixture="$tmp_dir/repo"
mkdir -p "$fixture"
cp "$repo_dir/rebuild.sh" "$fixture/rebuild.sh"
cp "$repo_dir/simple-rebuild.sh" "$fixture/simple-rebuild.sh"
chmod +x "$fixture/rebuild.sh" "$fixture/simple-rebuild.sh"

git -C "$fixture" init -q
git -C "$fixture" config user.name test
git -C "$fixture" config user.email test@example.invalid
printf 'base\n' > "$fixture/tracked.txt"
printf 'base\n' > "$fixture/flake.nix"
git -C "$fixture" add tracked.txt flake.nix
git -C "$fixture" commit -qm initial

printf 'unrelated edit\n' >> "$fixture/tracked.txt"
printf 'unrelated untracked\n' > "$fixture/notes.txt"
printf 'input = true\n' >> "$fixture/flake.nix"

# The real simple rebuild is not exercised: this stub makes it observable and
# ensures the test never invokes Nix or changes the host system.
cat > "$fixture/simple-rebuild.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fixture/simple-rebuild.sh"

# Nix's own profile path is prepended by rebuild.sh, so replace only the
# external update invocation in this isolated copy rather than invoking Nix.
sed "s|^nix --extra-experimental-features .* flake update$|: # stubbed flake update|" \
  "$fixture/rebuild.sh" > "$fixture/rebuild-test.sh"
chmod +x "$fixture/rebuild-test.sh"
zsh "$fixture/rebuild-test.sh"

if git -C "$fixture" diff --cached --quiet; then :; else
  echo 'rebuild staged changes unexpectedly' >&2
  exit 1
fi
git -C "$fixture" status --short | grep -Fq ' M tracked.txt'
git -C "$fixture" status --short | grep -Fq ' M flake.nix'
git -C "$fixture" status --short | grep -Fq '?? notes.txt'
echo 'rebuild staging regression passed'
