#!/usr/bin/env bash
# pm-dispatch-launch.sh -- launch one scheduled agent task via pm-dispatch.
#
# Extracted from .github/workflows/agents.yml (#1435): the bolt, palette
# and suggestions dispatch steps each inlined this identical sequence
# (prompt fetch, OIDC mint, payload construction, POST /v1/sessions,
# response check, output parsing), so a fix had to be made three times
# and the copies could drift. The steps now differ only in their env
# (INPUT_REPO / INPUT_TASK / INPUT_PROMPT_URL) and call this script.
#
# Interface (env, identical to the former inline steps):
#   INPUT_REPO, INPUT_TASK, INPUT_PROMPT_URL, INPUT_PROMPT_SHA256
#     (INPUT_PROMPT_SHA256 is new with #2038: the expected SHA-256 of
#     the prompt file at the pinned commit INPUT_PROMPT_URL names)
#   ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN
#     (provided by the runner when the job grants id-token: write)
#   GITHUB_OUTPUT -- receives task_id, session_id, issue_number,
#     issue_url, the keys the Summarize step consumes.
# Error messages and exit codes are unchanged from the inline version.
set -euo pipefail
# Inlined pm-dispatch-start (#1367): launch a tracked
# OpenCode session via pm-dispatch (POST /v1/sessions).
# Every request has a connect and total deadline shorter than the caller's
# 10-minute job timeout (agents.yml), so a stalled dependency fails this
# script with a stage diagnostic instead of consuming the whole job.
# Prompt trust (#2038): the fetched prompt becomes the dispatched
# agent's instructions, so it is verified before anything is minted or
# sent. agents.yml pins INPUT_PROMPT_URL to an immutable commit SHA of
# developing-today/code and sets INPUT_PROMPT_SHA256 to that prompt
# file's SHA-256 at the pin; a mismatch — or a missing digest — aborts
# here, before the OIDC mint below. The fetch goes to a file so the
# digest covers the exact bytes served, not a shell-trimmed copy.
prompt_file="$(mktemp)"
trap 'rm -f "$prompt_file"' EXIT
if ! curl -fsS --connect-timeout 10 --max-time 60 -o "$prompt_file" "$INPUT_PROMPT_URL"; then
  echo "::error::agents dispatch: failed to fetch prompt for task '$INPUT_TASK': $INPUT_PROMPT_URL" >&2
  exit 1
fi
if [ ! -s "$prompt_file" ]; then
  echo "::error::agents dispatch: prompt for task '$INPUT_TASK' is empty: $INPUT_PROMPT_URL" >&2
  exit 1
fi
if [ -z "${INPUT_PROMPT_SHA256:-}" ]; then
  echo "::error::agents dispatch: INPUT_PROMPT_SHA256 is not set for task '$INPUT_TASK'; refusing to dispatch an unverified prompt (#2038)." >&2
  exit 1
fi
actual_prompt_sha256="$(sha256sum "$prompt_file" | awk '{print $1}')"
if [ "$actual_prompt_sha256" != "$INPUT_PROMPT_SHA256" ]; then
  echo "::error::agents dispatch: prompt for task '$INPUT_TASK' failed SHA-256 verification: got $actual_prompt_sha256, expected $INPUT_PROMPT_SHA256 ($INPUT_PROMPT_URL). Refusing to dispatch." >&2
  exit 1
fi
resolved_prompt="$(cat "$prompt_file")"
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  echo "::error::agents dispatch: ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN are not set. The calling job must grant 'permissions: id-token: write' so an OIDC token can be minted." >&2
  exit 1
fi
task_capitalized="${INPUT_TASK^}"
title="Scheduled ${task_capitalized} — ${INPUT_REPO}"
if ! oidc_response="$(curl -sS --connect-timeout 10 --max-time 60 -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=pm-dispatch")"; then
  echo "::error::agents dispatch: OIDC token request failed or timed out (audience pm-dispatch)." >&2
  exit 1
fi
oidc_token="$(printf '%s' "$oidc_response" | jq -r '.value // empty')"
if [ -z "$oidc_token" ]; then
  echo "::error::agents dispatch: failed to mint a GitHub Actions OIDC token (audience pm-dispatch)." >&2
  exit 1
fi
payload="$(jq -n \
  --arg repo "$INPUT_REPO" \
  --arg title "$title" \
  --arg prompt "$resolved_prompt" \
  --argjson wait true \
  '{repo: $repo, title: $title, prompt: $prompt, wait: $wait}')"
if ! response="$(curl -sS --connect-timeout 10 --max-time 300 -w $'\n%{http_code}' -X POST "https://dispatch.security.cab/v1/sessions" \
  -H "Authorization: Bearer $oidc_token" \
  -H "Content-Type: application/json" \
  -d "$payload")"; then
  echo "::error::agents dispatch: pm-dispatch POST /v1/sessions failed or timed out (no HTTP response)." >&2
  exit 1
fi
http_code="${response##*$'\n'}"
body="${response%$'\n'*}"
if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
  echo "::error::agents dispatch: pm-dispatch POST /v1/sessions failed (HTTP $http_code):" >&2
  echo "$body" >&2
  exit 1
fi
echo "$body"
task_id="$(printf '%s' "$body" | jq -r '.task_id // empty')"
session_id="$(printf '%s' "$body" | jq -r '.session_id // empty')"
issue_number="$(printf '%s' "$body" | jq -r '.issue_number // empty')"
issue_url=""
if [ -n "$issue_number" ]; then
  issue_url="https://github.com/${INPUT_REPO}/issues/${issue_number}"
fi
{
  echo "task_id=$task_id"
  echo "session_id=$session_id"
  echo "issue_number=$issue_number"
  echo "issue_url=$issue_url"
} >> "$GITHUB_OUTPUT"
