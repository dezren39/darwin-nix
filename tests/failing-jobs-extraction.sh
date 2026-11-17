#!/usr/bin/env bash
# Hermetic regression for #1887: the main-broken watcher's failing-jobs
# extraction must read ALL pages of the jobs API. The old inline query
# read only the first page (API default 30) and substituted a
# "(no failed jobs reported)" sentinel, losing real matrix failures and
# collapsing distinct breakages onto one Breakage-ID.
#
# Drives the real .github/scripts/failing-jobs.sh against a stub `gh`
# that serves saved jobs-JSON pages and applies the caller's --jq
# program per page with real jq, exactly as `gh api --paginate --jq`
# does. The stub also records its arguments: if the script ever drops
# --paginate, the two-page case fails.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/fixtures"

# Build a jobs page: page_jobs <first-index> <count> -- ["<idx> <conclusion> <name>" ...]
# Job names default to "job-NN" with conclusion "success"; each triple
# overrides one position (the name is the rest of the triple, spaces kept).
page_jobs() {
  local first="$1" count="$2"
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  local triples=("$@")
  local i n name conclusion triple tidx tconclusion tname out
  out='{"total_count": '"$TOTAL_JOBS"', "jobs": ['
  for ((i = 0; i < count; i++)); do
    n=$((first + i))
    name="job-$n"
    conclusion="success"
    for triple in "${triples[@]}"; do
      read -r tidx tconclusion tname <<<"$triple"
      if [[ "$tidx" == "$n" ]]; then
        name="$tname"
        conclusion="$tconclusion"
      fi
    done
    [[ $i -gt 0 ]] && out+=","
    out+="{\"name\": \"$name\", \"conclusion\": \"$conclusion\"}"
  done
  out+="]}"
  printf '%s' "$out"
}

# Stub gh: emulates `gh api --paginate <jobs-path> --jq <prog>` over
# $FIXTURE_DIR/page*.json (one file per API page, in order), applying
# the caller's jq program to each page separately, as real gh does.
cat > "$work/bin/gh" <<EOF
#!$(command -v bash)
echo "gh \$*" >> "$work/gh-args.log"
jq_prog=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--jq" ]; then jq_prog="\$a"; fi
  prev="\$a"
done
for page in "$work/fixtures"/page*.json; do
  jq -r "\$jq_prog" "\$page"
done
EOF
chmod +x "$work/bin/gh"

run_extraction() {
  PATH="$work/bin:$PATH" bash "$repo/.github/scripts/failing-jobs.sh" "dezren39/darwin-nix" "42056207854"
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# ─── Case 1 (#1887 production shape): 41 jobs over two pages, the only
# failures at positions 32 and 37 — both beyond the first page of 30.
TOTAL_JOBS=41
page_jobs 1 30 -- > "$work/fixtures/page1.json"
page_jobs 31 11 -- "32 failure nix build laptop-agent-tests" "37 failure nix build clean-tests" > "$work/fixtures/page2.json"
: > "$work/gh-args.log"
got="$(run_extraction)"
[[ "$got" == "nix build clean-tests,nix build laptop-agent-tests" ]] ||
  fail "case 1: expected both page-2 failures named, got '$got'"
grep -q -- "--paginate" "$work/gh-args.log" ||
  fail "case 1: the extraction did not pass --paginate (pagination regression)"

# ─── Case 2 (control): failures inside the first page, incl. timed_out.
TOTAL_JOBS=3
page_jobs 1 3 -- "2 failure alpha job" "3 timed_out beta job" > "$work/fixtures/page1.json"
rm -f "$work/fixtures/page2.json"
got="$(run_extraction)"
[[ "$got" == "alpha job,beta job" ]] ||
  fail "case 2: expected 'alpha job,beta job', got '$got'"

# ─── Case 3: a failed run with no failed/timed-out job extracts empty
# (the watcher files nothing instead of a sentinel-titled issue).
TOTAL_JOBS=2
page_jobs 1 2 -- > "$work/fixtures/page1.json"
got="$(run_extraction)"
[[ -z "$got" ]] || fail "case 3: expected empty extraction, got '$got'"

echo "PASS: failing-jobs extraction reads all pages, includes timed_out, and is empty when nothing failed"
