#!/usr/bin/env bash
# Regression check for plannotator-setup (#2051): the command must run the
# installer only when its SHA-256 matches the pinned digest. Extracts the
# command body from systemPackages.nix and runs it with a stub curl.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

start="$(grep -n 'name = "plannotator-setup";' "$repo/systemPackages.nix" | cut -d: -f1)"
sed -n "$start,\$p" "$repo/systemPackages.nix" \
  | sed -n "/text = ''/,/^ *'';/p" | sed '1d;$d' | sed 's/^          //' > "$work/body.sh"
test -s "$work/body.sh"

pinned="$(grep -o '[0-9a-f]\{64\}' "$work/body.sh" | head -1)"
test -n "$pinned"

mkdir "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; esac
  shift
done
cp "$STUB_INSTALLER" "$out"
EOF
chmod +x "$work/bin/curl"

printf 'echo RAN >> "%s/ran"\n' "$work" > "$work/installer.sh"
printf 'echo TAMPERED >> "%s/ran"\n' "$work" > "$work/tampered.sh"

PATH="$work/bin:$PATH" STUB_INSTALLER="$work/tampered.sh" bash "$work/body.sh" >/dev/null 2>&1 && {
  echo "FAIL: mismatched installer should abort"; exit 1; }
test ! -e "$work/ran" || { echo "FAIL: mismatched installer executed"; exit 1; }

sed "s/$pinned/$(sha256sum "$work/installer.sh" | cut -d' ' -f1)/" "$work/body.sh" > "$work/body-match.sh"
PATH="$work/bin:$PATH" STUB_INSTALLER="$work/installer.sh" bash "$work/body-match.sh" >/dev/null 2>&1 || {
  echo "FAIL: matching installer should run"; exit 1; }
test -e "$work/ran" || { echo "FAIL: matching installer did not run"; exit 1; }

echo "plannotator-setup digest check: ok"
