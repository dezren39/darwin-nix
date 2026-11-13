#!/usr/bin/env bash
# Hermetic regression for #1801: `just fmt` must propagate flake-tidy failures.
# Stubs nixfmt and nix on PATH; no real flake state is touched.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/nixfmt" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$work/bin/nix" <<'EOF'
#!/usr/bin/env bash
exit "${STUB_TIDY_EXIT:-0}"
EOF
chmod +x "$work/bin/nixfmt" "$work/bin/nix"

run_fmt() {
  (cd "$repo" && PATH="$work/bin:$PATH" STUB_TIDY_EXIT="$1" just --justfile "$repo/justfile" fmt >/dev/null 2>&1)
}

if run_fmt 42; then
  echo "FAIL: just fmt exited 0 when flake-tidy failed" >&2
  exit 1
fi

if ! run_fmt 0; then
  echo "FAIL: just fmt exited nonzero on successful tidy" >&2
  exit 1
fi

echo "PASS: just fmt propagates flake-tidy failure and passes on success"
