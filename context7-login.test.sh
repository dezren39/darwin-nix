#!/usr/bin/env bash
# Regression test for just context7-login's success predicate (#1828).
#
# #1828: the recipe declared Context7 authenticated as soon as ANY path
# under ~/.mcp-auth matching '*token*' was modified in the last ten
# minutes, so signing in to (or refreshing) an unrelated OAuth server
# made it print "Authenticated" and exit 0 without Context7 credentials.
# mcp-remote stores per-URL credentials in ~/.mcp-auth/mcp-remote-v1/
# in files named <md5-of-URL>_tokens.json -- the URL is the identity
# (docs/mcp.md).
#
# This test extracts the REAL find predicate from the justfile's
# context7-login recipe (no pasted copy) and drives it against fixture
# auth dirs:
#   other server's recent _tokens.json   -> no match
#   Context7's recent _tokens.json       -> match
#   Context7's stale (20 min) _tokens    -> no match
#   Context7's recent _client_info.json  -> no match (not the token file)
#
# Run: bash context7-login.test.sh (exit 0 = all passed)
set -u

cd "$(dirname "$0")" || exit 1
failures=0

check() { # $1 name, $2 condition-result (0 = pass)
  if [ "$2" -eq 0 ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    failures=$((failures + 1))
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Extract the recipe's success predicate: the `find ... | grep -q .`
# pipeline on the context7-login polling line.
predicate=$(grep -F 'find "$auth" -name "$token_name"' justfile | sed -E 's/^[[:space:]]*if (.*); then$/\1/' | head -1)
[ -n "$predicate" ]
check "predicate extracted from justfile" $?
case "$predicate" in
  *'$token_name'*) check "predicate is scoped to \$token_name, not a '*token*' glob" 0 ;;
  *) check "predicate is scoped to \$token_name, not a '*token*' glob" 1 ;;
esac

url="https://mcp.context7.com/mcp"
if command -v md5sum >/dev/null 2>&1; then
  url_hash=$(printf %s "$url" | md5sum | cut -d ' ' -f 1)
else
  url_hash=$(md5 -q -s "$url")
fi
token_name="${url_hash}_tokens.json"
other_name="$(printf %s 'https://example.com/other-mcp' | { md5sum 2>/dev/null || md5 -q -s 'https://example.com/other-mcp'; } | cut -d ' ' -f 1)_tokens.json"
[ "$other_name" != "$token_name" ]
check "fixture hashes differ per URL" $?

run_predicate() { # $1 = fixture auth dir; returns predicate's exit code
  auth="$1" token_name="$token_name" bash -c "$predicate" >/dev/null 2>&1
}

# Case 1: only another server's recent token file exists.
mkdir -p "$work/other/mcp-remote-v1"
touch "$work/other/mcp-remote-v1/$other_name"
run_predicate "$work/other"
[ $? -ne 0 ]
check "recent token for another URL does not produce success" $?

# Case 2: Context7's own recent token file exists.
mkdir -p "$work/ctx/mcp-remote-v1"
touch "$work/ctx/mcp-remote-v1/$token_name"
run_predicate "$work/ctx"
check "recent Context7 token produces success" $?

# Case 3: Context7's token file exists but is stale (20 minutes old).
mkdir -p "$work/stale/mcp-remote-v1"
touch -d '20 minutes ago' "$work/stale/mcp-remote-v1/$token_name" 2>/dev/null \
  || touch -t "$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null)" "$work/stale/mcp-remote-v1/$token_name"
run_predicate "$work/stale"
[ $? -ne 0 ]
check "stale Context7 token does not produce success" $?

# Case 4: only Context7's client-info file is recent (no token file).
mkdir -p "$work/info/mcp-remote-v1"
touch "$work/info/mcp-remote-v1/${url_hash}_client_info.json"
run_predicate "$work/info"
[ $? -ne 0 ]
check "recent client-info without the token file does not produce success" $?

if [ "$failures" -eq 0 ]; then
  echo "all context7-login predicate tests passed"
else
  echo "$failures context7-login predicate test(s) FAILED" >&2
  exit 1
fi
