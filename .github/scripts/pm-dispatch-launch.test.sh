#!/usr/bin/env bash
# Regression test for .github/scripts/pm-dispatch-launch.sh (#1435).
#
# The launch sequence used to be inlined identically in agents.yml's
# three dispatch steps; it now lives once in pm-dispatch-launch.sh.
# This suite drives the REAL script with a stub curl (the only network
# tool it calls) and the real jq, and pins the observable contract the
# workflow depends on:
#   happy path   -> payload {repo, title "Scheduled <Task> — <repo>",
#                   prompt, wait: true} POSTed with the minted token;
#                   GITHUB_OUTPUT gets task_id / session_id /
#                   issue_number / issue_url (the Summarize step's keys)
#   non-2xx      -> exit 1, error names the HTTP code
#   prompt fetch -> exit 1, error names the task and URL
#   empty prompt -> exit 1, error says the prompt is empty
#   digest wrong -> exit 1, error says SHA-256 verification failed,
#                   and nothing is dispatched (no payload recorded)
#   digest unset -> exit 1, error names INPUT_PROMPT_SHA256
#   no OIDC env  -> exit 1, error names the missing runner variables
#   empty token  -> exit 1, error says the mint failed
#   hung calls   -> each of the three requests is bounded by a
#                   --max-time shorter than the 10-minute job timeout;
#                   a stalled call exits 28 and the error names its stage
#
# Run: bash .github/scripts/pm-dispatch-launch.test.sh (exit 0 = passed)
set -u

cd "$(dirname "$0")" || exit 1
SCRIPT="./pm-dispatch-launch.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }
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
mkdir -p "$work/bin"

# Stub curl: answers the script's three call shapes by URL, records the
# POST payload, and is steered per-case by STUB_* env. The shebang names
# this bash by path: the nix build sandbox has no /usr/bin/env (#978).
{ printf '#!%s\n' "$(command -v bash)"; cat <<'STUB'
url=""
payload=""
output_file=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then payload=$a; fi
  if [ "$prev" = "-o" ]; then output_file=$a; fi
  case "$a" in http*) url=$a ;; esac
  prev=$a
done
stage=""
case "$url" in
  *prompts/*) stage=prompt ;;
  *audience=pm-dispatch*) stage=oidc ;;
  *dispatch.security.cab*) stage=dispatch ;;
esac
if [ -n "$stage" ] && [ "${STUB_HANG:-}" = "$stage" ]; then
  max=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--max-time" ]; then max=$a; fi
    prev=$a
  done
  case "$max" in
    ''|*[!0-9]*) echo "stub curl: $stage call has no --max-time (would hang)" >&2; exit 99 ;;
  esac
  if [ "$max" -ge 600 ]; then echo "stub curl: $stage --max-time $max >= job timeout" >&2; exit 99; fi
  printf '%s\n' "$stage" >> "$STUB_DEADLINE_VALIDATION_FILE"
  exit 28
fi
case "$url" in
  *prompts/*)
    [ "${STUB_PROMPT_FAIL:-0}" = "1" ] && exit 22
    if [ -n "$output_file" ]; then
      printf '%s' "${STUB_PROMPT-stub prompt body}" > "$output_file"
    else
      printf '%s' "${STUB_PROMPT-stub prompt body}"
    fi
    ;;
  *audience=pm-dispatch*)
    if [ "${STUB_TOKEN_EMPTY:-0}" = "1" ]; then
      printf '{"value":""}'
    else
      printf '{"value":"stub-oidc-token"}'
    fi
    ;;
  *dispatch.security.cab*)
    printf '%s' "$payload" > "$STUB_PAYLOAD_FILE"
    printf '%s\n%s' "${STUB_RESPONSE_BODY:-{\}}" "${STUB_HTTP_CODE:-201}"
    ;;
  *)
    echo "stub curl: unexpected URL: $url" >&2
    exit 99
    ;;
esac
STUB
} > "$work/bin/curl"
chmod +x "$work/bin/curl"

run_launch() { # extra env assignments as args; sets rc, out, err
  : > "$work/github-output"
  : > "$work/deadline-validation"
  : > "$work/payload.json"
  env -i PATH="$work/bin:$PATH" HOME="$work" \
    INPUT_REPO="dezren39/darwin-nix" INPUT_TASK="bolt" \
    INPUT_PROMPT_URL="https://example.test/prompts/bolt.md" \
    INPUT_PROMPT_SHA256="d801f7aec918a09accec5c163fcdd2e5f7cc331d988717694007f68f53f2c1ea" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://example.test/oidc?tok=req" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="req-token" \
    GITHUB_OUTPUT="$work/github-output" \
    STUB_PAYLOAD_FILE="$work/payload.json" \
    STUB_DEADLINE_VALIDATION_FILE="$work/deadline-validation" \
    STUB_RESPONSE_BODY='{"task_id":"T-1","session_id":"S-1","issue_number":42}' \
    "$@" bash "$SCRIPT" > "$work/out" 2> "$work/err"
  echo $?
}

# --- happy path -------------------------------------------------------------
rc=$(run_launch)
[ "$rc" -eq 0 ]; check "happy path exits 0" "$?"
grep -qx 'task_id=T-1' "$work/github-output"; check "output task_id" "$?"
grep -qx 'session_id=S-1' "$work/github-output"; check "output session_id" "$?"
grep -qx 'issue_number=42' "$work/github-output"; check "output issue_number" "$?"
grep -qx 'issue_url=https://github.com/dezren39/darwin-nix/issues/42' "$work/github-output"
check "output issue_url derived from repo + number" "$?"
[ "$(jq -r .repo "$work/payload.json")" = "dezren39/darwin-nix" ]; check "payload repo" "$?"
[ "$(jq -r .title "$work/payload.json")" = "Scheduled Bolt — dezren39/darwin-nix" ]
check "payload title is Scheduled <Capitalized task> — <repo>" "$?"
[ "$(jq -r .prompt "$work/payload.json")" = "stub prompt body" ]; check "payload prompt is the fetched prompt" "$?"
[ "$(jq -r .wait "$work/payload.json")" = "true" ]; check "payload wait is true" "$?"

# --- non-2xx response ---------------------------------------------------------
rc=$(run_launch STUB_HTTP_CODE=500 STUB_RESPONSE_BODY='{"error":"boom"}')
[ "$rc" -eq 1 ]; check "non-2xx exits 1" "$?"
grep -q 'pm-dispatch POST /v1/sessions failed (HTTP 500)' "$work/err"
check "non-2xx error names the HTTP code" "$?"

# --- prompt fetch failure -----------------------------------------------------
rc=$(run_launch STUB_PROMPT_FAIL=1)
[ "$rc" -eq 1 ]; check "prompt fetch failure exits 1" "$?"
grep -q "failed to fetch prompt for task 'bolt'" "$work/err"
check "prompt fetch error names the task" "$?"

# --- empty prompt ---------------------------------------------------------------
rc=$(run_launch STUB_PROMPT='')
[ "$rc" -eq 1 ]; check "empty prompt exits 1" "$?"
grep -q "prompt for task 'bolt' is empty" "$work/err"
check "empty prompt error says so" "$?"

# --- prompt digest mismatch (#2038) ---------------------------------------------
rc=$(run_launch INPUT_PROMPT_SHA256=0000000000000000000000000000000000000000000000000000000000000000)
[ "$rc" -eq 1 ]; check "prompt digest mismatch exits 1" "$?"
grep -q 'failed SHA-256 verification' "$work/err"
check "digest mismatch error says verification failed" "$?"
[ ! -s "$work/payload.json" ]; check "digest mismatch aborts before the dispatch POST" "$?"

# --- prompt digest matches a non-default prompt (#2038) -------------------------
rc=$(run_launch STUB_PROMPT='custom body' INPUT_PROMPT_SHA256=4cb1e567dac92b55ad040bb99b7e93f559406284a9e22b05f71b2ee4c19e0d41)
[ "$rc" -eq 0 ]; check "matching digest for a custom prompt exits 0" "$?"
[ "$(jq -r .prompt "$work/payload.json")" = "custom body" ]; check "payload prompt is the verified custom prompt" "$?"

# --- prompt digest unset (#2038) --------------------------------------------------
: > "$work/github-output"
: > "$work/payload.json"
env -i PATH="$work/bin:$PATH" HOME="$work" \
  INPUT_REPO="dezren39/darwin-nix" INPUT_TASK="bolt" \
  INPUT_PROMPT_URL="https://example.test/prompts/bolt.md" \
  ACTIONS_ID_TOKEN_REQUEST_URL="https://example.test/oidc?tok=req" \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN="req-token" \
  GITHUB_OUTPUT="$work/github-output" \
  STUB_PAYLOAD_FILE="$work/payload.json" \
  STUB_DEADLINE_VALIDATION_FILE="$work/deadline-validation" \
  bash "$SCRIPT" > "$work/out" 2> "$work/err"
rc=$?
[ "$rc" -eq 1 ]; check "missing prompt digest exits 1" "$?"
grep -q 'INPUT_PROMPT_SHA256 is not set' "$work/err"
check "missing digest error names INPUT_PROMPT_SHA256" "$?"
[ ! -s "$work/payload.json" ]; check "missing digest aborts before the dispatch POST" "$?"

# --- missing OIDC env -----------------------------------------------------------
: > "$work/github-output"
env -i PATH="$work/bin:$PATH" HOME="$work" \
  INPUT_REPO="dezren39/darwin-nix" INPUT_TASK="bolt" \
  INPUT_PROMPT_URL="https://example.test/prompts/bolt.md" \
  INPUT_PROMPT_SHA256="d801f7aec918a09accec5c163fcdd2e5f7cc331d988717694007f68f53f2c1ea" \
  GITHUB_OUTPUT="$work/github-output" \
  STUB_PAYLOAD_FILE="$work/payload.json" \
  STUB_DEADLINE_VALIDATION_FILE="$work/deadline-validation" \
  bash "$SCRIPT" > "$work/out" 2> "$work/err"
rc=$?
[ "$rc" -eq 1 ]; check "missing OIDC env exits 1" "$?"
grep -q 'ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN are not set' "$work/err"
check "missing OIDC env error names the variables" "$?"

# --- empty minted token -----------------------------------------------------------
rc=$(run_launch STUB_TOKEN_EMPTY=1)
[ "$rc" -eq 1 ]; check "empty minted token exits 1" "$?"
grep -q 'failed to mint a GitHub Actions OIDC token' "$work/err"
check "empty token error says the mint failed" "$?"

for stage in prompt oidc dispatch; do
  rc=$(run_launch STUB_HANG="$stage")
  [ "$rc" -eq 1 ]; check "hung $stage call exits 1 (bounded, not hung)" "$?"
  grep -qx "$stage" "$work/deadline-validation"
  check "hung $stage stub accepted a sub-600-second --max-time" "$?"
done
rc=$(run_launch STUB_HANG=prompt)
grep -q "failed to fetch prompt for task 'bolt'" "$work/err"; check "hung prompt fetch names the stage" "$?"
rc=$(run_launch STUB_HANG=oidc)
grep -q 'OIDC token request failed or timed out' "$work/err"; check "hung OIDC request names the stage" "$?"
rc=$(run_launch STUB_HANG=dispatch)
grep -q 'pm-dispatch POST /v1/sessions failed or timed out' "$work/err"; check "hung dispatch POST names the stage" "$?"

if [ "$failures" -gt 0 ]; then
  echo "FAILURES: $failures"
  exit 1
fi
echo "ALL PASS"
