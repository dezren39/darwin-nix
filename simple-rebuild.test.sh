#!/usr/bin/env bash
# Regression test for simple-rebuild.sh's mode-flag parser (#1149).
#
# --build-only and --activate-only are documented alternatives
# ([--build-only|--activate-only [GENERATION]]) but the parser assigned
# mode unconditionally, so both together silently last-won:
# `--build-only --activate-only` ran the sudo activation phase, the
# reverse silently dropped to a build, a repeated --activate-only
# silently discarded the first GENERATION, and
# `--activate-only 5 --build-only` stranded the generation in a build
# run, exit 0. The build/activate split is a privilege boundary
# (no sudo vs sudo), so the parser now rejects all of those at parse
# time with exit 2 naming the flags.
#
# This suite cannot drive the real script end to end (a valid control
# would run a real nix build / darwin activation), so it extracts the
# REAL parser segment from simple-rebuild.sh -- from `mode="all"`
# through the GENERATION and HEALTH_TIMEOUT validation, stopping at the
# end-of-parse marker comment -- and runs that segment under zsh, the
# script's interpreter.
# Nothing is a pasted copy: if the shipped parser changes, the
# extracted segment changes with it, and a missing marker fails here.
#
# Run: ./simple-rebuild.test.sh
# It is run by the flake check `simple-rebuild-tests`.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/simple-rebuild.sh"

command -v zsh >/dev/null || { echo "zsh required" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $1"; }

# Extract the parser segment from the real script.
SEGMENT="$TMP_ROOT/parser.zsh"
awk '/^mode="all"/{f=1} /^# End of parse-time validation/{f=0} f' "$SCRIPT" >"$SEGMENT"
[ -s "$SEGMENT" ] || { echo "could not extract parser segment from simple-rebuild.sh" >&2; exit 1; }
grep -q 'seen_activate' "$SEGMENT" || fail "extracted segment lacks the #1149 mode-flag guards"
grep -q 'HEALTH_TIMEOUT' "$SEGMENT" || fail "extracted segment lacks the HEALTH_TIMEOUT validation"

# --- Ordering pin (#1316): parse + validation precede side effects ---
line_of() { grep -n -m1 -- "$1" "$SCRIPT" | cut -d: -f1; }
parse_line="$(line_of '^mode="all"')"
gen_line="$(line_of 'GENERATION must be a positive integer')"
ht_line="$(line_of 'HEALTH_TIMEOUT must be a positive integer')"
reclaim_line="$(line_of '^reclaim_root_owned$')"
gitadd_line="$(awk '/^  stage_flake_inputs$/{print NR; exit}' "$SCRIPT")"
token_line="$(line_of '^refresh_nix_access_token$')"
if [ -n "$parse_line" ] && [ -n "$gen_line" ] && [ -n "$ht_line" ] && [ -n "$reclaim_line" ] \
  && [ -n "$gitadd_line" ] && [ -n "$token_line" ] \
  && [ "$parse_line" -lt "$reclaim_line" ] && [ "$parse_line" -lt "$gitadd_line" ] \
  && [ "$parse_line" -lt "$token_line" ] && [ "$gen_line" -lt "$reclaim_line" ] \
  && [ "$ht_line" -lt "$reclaim_line" ]; then
  ok "parse + GENERATION + HEALTH_TIMEOUT validation precede reclaim/git add/token refresh (#1316)"
else
  fail "ordering pin (#1316): parse=$parse_line gen=$gen_line ht=$ht_line reclaim=$reclaim_line gitadd=$gitadd_line token=$token_line"
fi

PROBE="$TMP_ROOT/probe.zsh"
cat >"$PROBE" <<EOF
#!/usr/bin/env zsh
source "$SEGMENT" "\$@"
echo "mode=\$mode generation=\$generation no_commit=\$no_commit"
EOF

run() { # run <args...> -- sets OUT, ERR, STATUS
  OUT="$(zsh "$PROBE" "$@" 2>"$TMP_ROOT/err")"; STATUS=$?
  ERR="$(cat "$TMP_ROOT/err")"
}

expect_reject() { # expect_reject <label> <needle1> <needle2> <args...>
  local label="$1" n1="$2" n2="$3"; shift 3
  run "$@"
  [ "$STATUS" -eq 2 ] || { fail "$label exited $STATUS (want 2)"; return; }
  case "$ERR" in *"$n1"*) : ;; *) fail "$label stderr did not name $n1 (got: $ERR)"; return ;; esac
  if [ -n "$n2" ]; then
    case "$ERR" in *"$n2"*) : ;; *) fail "$label stderr did not name $n2 (got: $ERR)"; return ;; esac
  fi
  ok "$label rejected, exit 2, flags named"
}

expect_parse() { # expect_parse <label> <want mode=...> <args...>
  local label="$1" want="$2"; shift 2
  run "$@"
  [ "$STATUS" -eq 0 ] || { fail "$label exited $STATUS (want 0; err: $ERR)"; return; }
  [ "$OUT" = "$want" ] || { fail "$label parsed as '$OUT' (want '$want')"; return; }
  ok "$label parses as $want"
}

# --- Conflicting / repeated mode flags are rejected at parse time ---
expect_reject "--build-only --activate-only" "--build-only" "--activate-only" --build-only --activate-only
expect_reject "--activate-only --build-only" "--activate-only" "--build-only" --activate-only --build-only
expect_reject "--build-only --activate-only 5" "--build-only" "--activate-only" --build-only --activate-only 5
expect_reject "--activate-only 5 --build-only (stranded generation)" "--activate-only" "--build-only" --activate-only 5 --build-only
expect_reject "--activate-only 5 --activate-only 7" "--activate-only" "" --activate-only 5 --activate-only 7
expect_reject "--activate-only --activate-only" "--activate-only" "" --activate-only --activate-only
expect_reject "--no-commit --build-only --activate-only" "--build-only" "--activate-only" --no-commit --build-only --activate-only

# --- Valid invocations parse exactly as before ----------------------
expect_parse "no flags" "mode=all generation= no_commit=0"
expect_parse "--build-only" "mode=build generation= no_commit=0" --build-only
expect_parse "--activate-only" "mode=activate generation= no_commit=0" --activate-only
expect_parse "--activate-only 5" "mode=activate generation=5 no_commit=0" --activate-only 5
expect_parse "--no-commit" "mode=all generation= no_commit=1" --no-commit
expect_parse "--no-commit --build-only" "mode=build generation= no_commit=1" --no-commit --build-only
expect_parse "--build-only --no-commit" "mode=build generation= no_commit=1" --build-only --no-commit
expect_parse "--activate-only 5 --no-commit" "mode=activate generation=5 no_commit=1" --activate-only 5 --no-commit

# --- Pre-existing parser behaviour is intact ------------------------
# GENERATION validation (#1022): non-numeric still exits 2, and
# leading zeros are still normalised away.
expect_reject "--activate-only abc" "GENERATION" "" --activate-only abc
expect_parse "--activate-only 007" "mode=activate generation=7 no_commit=0" --activate-only 007
expect_reject "--bogus" "usage:" "" --bogus

# --- -h/--help: usage on stdout, exit 0, decided at parse time -------
expect_help() { # expect_help <flag>
  run "$1"
  [ "$STATUS" -eq 0 ] || { fail "$1 exited $STATUS (want 0)"; return; }
  case "$OUT" in *"usage:"*) ok "$1 prints usage, exit 0" ;; *) fail "$1 stdout lacked usage (got: $OUT)" ;; esac
}
expect_help --help
expect_help -h

# --- Help plus an extra argument is a usage error (#1888) ------------
# The parser used to exit 0 on the first -h/--help token, so anything
# after it was never validated. Now the complete command line is
# accounted for before help is honored: an unaccounted argument after
# help is rejected with exit 2 naming it, and a fully accounted line
# that includes help still prints usage and exits 0.
expect_reject "--help unexpected" "unexpected" "" --help unexpected
expect_reject "-h --bogus" "--bogus" "" -h --bogus
expect_reject "--help --bogus" "--bogus" "" --help --bogus
expect_help_args() { # expect_help_args <label> <args...>
  local label="$1"; shift
  run "$@"
  [ "$STATUS" -eq 0 ] || { fail "$label exited $STATUS (want 0)"; return; }
  case "$OUT" in *"usage:"*) ok "$label prints usage, exit 0" ;; *) fail "$label stdout lacked usage (got: $OUT)" ;; esac
}
expect_help_args "--no-commit --help (fully accounted)" --no-commit --help
expect_help_args "--build-only --help (fully accounted)" --build-only --help

# --- Error headline color gate follows stderr's tty + NO_COLOR state ----
GATE="$TMP_ROOT/color-gate.zsh"
awk '/^print_error\(\) \{$/ { capture=1 } capture { print } capture && /^}$/ { exit }' "$SCRIPT" >"$GATE"
[ -s "$GATE" ] || { echo "could not extract print_error from simple-rebuild.sh" >&2; exit 1; }
grep -Fq '[[ -t 2 && -z "${NO_COLOR:-}" ]]' "$GATE" \
  || fail "error color gate must test stderr tty and NO_COLOR"
grep -Fq 'print_error "==> build failed; nothing activated, nothing committed"' "$SCRIPT" \
  || fail "build failure headline does not use print_error"
grep -Fq 'print_error "==> $label is not up"' "$SCRIPT" \
  || fail "agent failure headline does not use print_error"
grep -Fq 'print_error "==> switch done and recorded, but $failed agent(s) are not up (above)" >&2' "$SCRIPT" \
  || fail "activation health headline does not use print_error on stderr"

GATE_PROBE="$TMP_ROOT/color-gate-probe.zsh"
cat >"$GATE_PROBE" <<EOF
source "$GATE"
print_error "gate probe"
EOF
for gate_mode in captured no-color; do
  if [ "$gate_mode" = no-color ]; then
    NO_COLOR=1 zsh "$GATE_PROBE" >"$TMP_ROOT/gate.out" 2>"$TMP_ROOT/gate.err"
  else
    zsh "$GATE_PROBE" >"$TMP_ROOT/gate.out" 2>"$TMP_ROOT/gate.err"
  fi
  gate_err="$(cat "$TMP_ROOT/gate.err")"
  [ ! -s "$TMP_ROOT/gate.out" ] || fail "$gate_mode error headline wrote to stdout"
  [ "$gate_err" = "gate probe" ] || fail "$gate_mode stderr was '$gate_err' (want plain 'gate probe')"
  case "$gate_err" in
    *$'\033'*) fail "$gate_mode captured stderr contains ANSI escape bytes" ;;
    *) ok "$gate_mode stderr is plain and escape-free" ;;
  esac
done

# --- HEALTH_TIMEOUT validation runs inside the extracted segment -----
OUT="$(HEALTH_TIMEOUT=abc zsh "$PROBE" 2>"$TMP_ROOT/err")"; STATUS=$?
ERR="$(cat "$TMP_ROOT/err")"
if [ "$STATUS" -eq 2 ]; then
  case "$ERR" in *"HEALTH_TIMEOUT"*) ok "HEALTH_TIMEOUT=abc rejected at parse time, exit 2" ;; *) fail "HEALTH_TIMEOUT=abc stderr did not name HEALTH_TIMEOUT (got: $ERR)" ;; esac
else
  fail "HEALTH_TIMEOUT=abc exited $STATUS (want 2)"
fi

# The mcpx health check must read MCPX_CONFIG from launchd when it runs
# (a pre-switch shell carries the old value), so the entry must name
# `launchctl getenv MCPX_CONFIG` and be single-quoted: a double-quoted
# entry expands the lookup when the array is defined, before activation.
MCPX_ENTRY=$(grep -E "^[[:space:]]*['\"]org\.nixos\.mcpx cmd:" "$SCRIPT" || true)
if [ -z "$MCPX_ENTRY" ]; then
  fail "mcpx health entry not found in simple-rebuild.sh"
else
  case "$MCPX_ENTRY" in
    *"launchctl getenv MCPX_CONFIG"*) ok "mcpx health check reads MCPX_CONFIG from launchd" ;;
    *) fail "mcpx health check does not read MCPX_CONFIG from launchd (got: $MCPX_ENTRY)" ;;
  esac
  case "$MCPX_ENTRY" in
    *"'org.nixos.mcpx"*) ok "mcpx health entry is single-quoted (lookup runs at check time)" ;;
    *) fail "mcpx health entry is not single-quoted (got: $MCPX_ENTRY)" ;;
  esac
fi

# --- brew_upgrade skip branch survives a missing Brewfile (#2031) ----
# grep finds no Brewfile path in ./result/activate, so the pipeline exits 1;
# under pipefail + errexit that aborted ./s before the documented skip
# branch ran, leaving a completed switch unrecorded. The real function is
# extracted and run under the script's own shell options.
BREW_FN="$TMP_ROOT/brew-upgrade.sh"
awk '/^brew_upgrade\(\) \{$/ { capture=1 } capture { print } capture && /^}$/ { exit }' "$SCRIPT" >"$BREW_FN"
if [ ! -s "$BREW_FN" ]; then
  fail "could not extract brew_upgrade from simple-rebuild.sh"
else
  BREW_RUN="$TMP_ROOT/brew-upgrade-run"
  mkdir -p "$BREW_RUN/result"
  printf '#!/bin/sh\necho activation-with-no-brewfile\n' >"$BREW_RUN/result/activate"
  cat >"$BREW_RUN/driver.sh" <<EOF
set -exuo pipefail
cd "$BREW_RUN"
source "$BREW_FN"
brew_upgrade
echo "after-brew-upgrade"
EOF
  BREW_OUT="$(bash "$BREW_RUN/driver.sh" 2>"$TMP_ROOT/brew.err")"; BREW_STATUS=$?
  if [ "$BREW_STATUS" -ne 0 ]; then
    fail "brew_upgrade with no Brewfile path exited $BREW_STATUS (want 0)"
  else
    ok "brew_upgrade with no Brewfile path exits 0"
  fi
  case "$(cat "$TMP_ROOT/brew.err")" in
    *"skipping brew upgrade: no Brewfile"*) ok "brew_upgrade prints the skip message" ;;
    *) fail "brew_upgrade did not print the skip message" ;;
  esac
  case "$BREW_OUT" in
    *after-brew-upgrade*) ok "script continues after brew_upgrade (record_activation still reached)" ;;
    *) fail "script aborted inside brew_upgrade before the skip branch returned" ;;
  esac
fi

# --- agent_answers cmd branch is time-bounded (#2101) ---------------
# The cmd:* branch ran a bare (eval ...) with no timeout, so one hung
# command check pinned check_services past HEALTH_TIMEOUT -- the
# deadline there is only tested after agent_answers returns. The real
# function is extracted from simple-rebuild.sh and run under zsh, the
# script's interpreter. curl is stubbed so the HTTP branch is exercised
# without a network.
AGENT_FN="$TMP_ROOT/agent-answers.zsh"
awk '/^agent_answers\(\) \{$/ { capture=1 } capture { print } capture && /^}$/ { exit }' "$SCRIPT" >"$AGENT_FN"
if [ ! -s "$AGENT_FN" ]; then
  fail "could not extract agent_answers from simple-rebuild.sh"
else
  AGENT_RUN="$TMP_ROOT/agent-answers-run"
  mkdir -p "$AGENT_RUN/bin"
  cat >"$AGENT_RUN/bin/curl" <<'EOF'
#!/bin/sh
printf '%s' "${FAKE_HTTP_CODE:-000}"
EOF
  chmod +x "$AGENT_RUN/bin/curl"
  cat >"$AGENT_RUN/driver.zsh" <<EOF
source "$AGENT_FN"
agent_answers "\$1"
EOF
  # agent_case <check> <HEALTH_TIMEOUT or "">: sets AGENT_STATUS,
  # AGENT_ELAPSED (whole seconds) and AGENT_ERR for the run.
  agent_case() {
    local check="$1" ht="$2" start
    start=$(date +%s)
    if [ -n "$ht" ]; then
      PATH="$AGENT_RUN/bin:$PATH" HEALTH_TIMEOUT="$ht" zsh "$AGENT_RUN/driver.zsh" "$check" 2>"$TMP_ROOT/agent.err"
    else
      PATH="$AGENT_RUN/bin:$PATH" zsh "$AGENT_RUN/driver.zsh" "$check" 2>"$TMP_ROOT/agent.err"
    fi
    AGENT_STATUS=$?
    AGENT_ELAPSED=$(( $(date +%s) - start ))
    AGENT_ERR="$(cat "$TMP_ROOT/agent.err")"
  }

  agent_case "cmd:true" ""
  if [ "$AGENT_STATUS" -eq 0 ] && [ "$AGENT_ELAPSED" -lt 10 ]; then
    ok "agent_answers cmd:true answers 0 promptly (#2101)"
  else
    fail "agent_answers cmd:true gave status $AGENT_STATUS after ${AGENT_ELAPSED}s (want 0, fast)"
  fi

  agent_case "cmd:false" ""
  if [ "$AGENT_STATUS" -eq 1 ] && [ "$AGENT_ELAPSED" -lt 10 ]; then
    ok "agent_answers cmd:false answers 1 promptly (#2101)"
  else
    fail "agent_answers cmd:false gave status $AGENT_STATUS after ${AGENT_ELAPSED}s (want 1, fast)"
  fi

  agent_case "-" ""
  if [ "$AGENT_STATUS" -eq 0 ]; then
    ok "agent_answers - still answers 0 (#2101)"
  else
    fail "agent_answers - gave status $AGENT_STATUS (want 0)"
  fi

  agent_case "cmd:sleep 30" ""
  if [ "$AGENT_STATUS" -eq 1 ] && [ "$AGENT_ELAPSED" -lt 20 ]; then
    ok "agent_answers hung cmd:sleep 30 fails within the bound, not after 30s (#2101)"
  else
    fail "agent_answers cmd:sleep 30 gave status $AGENT_STATUS after ${AGENT_ELAPSED}s (want 1, well under 30)"
  fi
  case "$AGENT_ERR" in
    *"timed out"*"sleep 30"*) ok "agent_answers timeout diagnostic names the hung check (#2101)" ;;
    *) fail "agent_answers timeout diagnostic did not name the hung check (got: $AGENT_ERR)" ;;
  esac

  # A timeout must also stop descendants, not just the shell running the
  # probe; otherwise each failed switch can leave another long-lived child.
  rm -f "$TMP_ROOT/health-child.pid"
  agent_case "cmd:sleep 30 & echo \$! > '$TMP_ROOT/health-child.pid'; wait" "1"
  if [ -s "$TMP_ROOT/health-child.pid" ]; then
    HEALTH_CHILD=$(cat "$TMP_ROOT/health-child.pid")
    case "$HEALTH_CHILD" in
      ''|*[!0-9]*) fail "invalid health child pid: $HEALTH_CHILD"; exit 1 ;;
    esac
    # Darwin's Nix build PATH omits the system utilities. Use the stock
    # ps there; Linux supplies procps through nativeBuildInputs. Keep the
    # assertion mandatory rather than silently skipping descendant cleanup.
    HEALTH_PS=$(command -v ps || true)
    if [ -z "$HEALTH_PS" ] && [ "$(uname -s)" = Darwin ] && [ -x /bin/ps ]; then
      HEALTH_PS=/bin/ps
    fi
    [ -n "$HEALTH_PS" ] || { fail "ps required to verify child cleanup"; exit 1; }
    if [ "$AGENT_STATUS" -ne 1 ] || [ "$AGENT_ELAPSED" -ge 10 ]; then
      fail "descendant probe exited $AGENT_STATUS after ${AGENT_ELAPSED}s (want 1, under 10s)"
    fi
    HEALTH_CHILD_STATE=""
    for _ in 1 2 3 4 5; do
      HEALTH_CHILD_STATE=$("$HEALTH_PS" -o stat= -p "$HEALTH_CHILD" 2>/dev/null | tr -d ' ')
      case "$HEALTH_CHILD_STATE" in
        ''|Z*) break ;;
      esac
      sleep 1
    done
    case "$HEALTH_CHILD_STATE" in
      ''|Z*) ok "agent_answers timeout terminates spawned child processes (#2221)" ;;
      *) fail "agent_answers left child $HEALTH_CHILD alive after timeout (state: $HEALTH_CHILD_STATE)"
         kill "$HEALTH_CHILD" 2>/dev/null || true ;;
    esac
  else
    fail "agent_answers descendant test did not record a child pid"
  fi

  agent_case "cmd:sleep 30" "3"
  if [ "$AGENT_STATUS" -eq 1 ] && [ "$AGENT_ELAPSED" -lt 15 ]; then
    ok "agent_answers hung check is bounded by HEALTH_TIMEOUT=3 when that is smaller (#2101)"
  else
    fail "agent_answers cmd:sleep 30 with HEALTH_TIMEOUT=3 gave status $AGENT_STATUS after ${AGENT_ELAPSED}s (want 1, well under 30)"
  fi

  FAKE_HTTP_CODE=200 agent_case "http://127.0.0.1:9/" ""
  if [ "$AGENT_STATUS" -eq 0 ]; then
    ok "agent_answers HTTP branch still answers 0 on a 200 (#2101)"
  else
    fail "agent_answers HTTP branch gave status $AGENT_STATUS on a stubbed 200 (want 0)"
  fi

  FAKE_HTTP_CODE=000 agent_case "http://127.0.0.1:9/" ""
  if [ "$AGENT_STATUS" -eq 1 ]; then
    ok "agent_answers HTTP branch still answers 1 on a 000 (#2101)"
  else
    fail "agent_answers HTTP branch gave status $AGENT_STATUS on a stubbed 000 (want 1)"
  fi
fi

# --- check_services enforces the HEALTH_TIMEOUT deadline (#2020) ----
# The polling loop ran its PID/health success test before the deadline
# check, so a service first seen healthy in the 3s settle sleep --
# already past HEALTH_TIMEOUT -- was still reported up. The real
# function is extracted from simple-rebuild.sh and run under zsh with
# agent_pid / agent_answers / report_agent / print_error stubbed: the
# pid is stable and health always answers, so in the late case the
# deadline itself is the only thing that can refuse acceptance.
SVC_FN="$TMP_ROOT/check-services.zsh"
awk '/^check_services\(\) \{$/ { capture=1 } capture { print } capture && /^}$/ { exit }' "$SCRIPT" >"$SVC_FN"
if [ ! -s "$SVC_FN" ]; then
  fail "could not extract check_services from simple-rebuild.sh"
else
  SVC_RUN="$TMP_ROOT/check-services-run"
  mkdir -p "$SVC_RUN"
  cat >"$SVC_RUN/driver.zsh" <<EOF
agent_pid() { echo 1234; }
agent_answers() { return 0; }
report_agent() { echo "not up: \$1" >&2; }
print_error() { echo "\$*" >&2; }
health_services=("org.example.test -")
source "$SVC_FN"
check_services
EOF
  # svc_case <HEALTH_TIMEOUT>: sets SVC_STATUS, SVC_OUT and SVC_ERR.
  svc_case() {
    SVC_OUT="$(HEALTH_TIMEOUT="$1" zsh "$SVC_RUN/driver.zsh" 2>"$TMP_ROOT/svc.err")"
    SVC_STATUS=$?
    SVC_ERR="$(cat "$TMP_ROOT/svc.err")"
  }

  # Late success: HEALTH_TIMEOUT=1 expires during the settle sleep, so
  # the (stubbed, succeeding) health check is first observed after the
  # deadline and must not be accepted as on-time.
  svc_case 1
  if [ "$SVC_STATUS" -ne 0 ]; then
    ok "check_services refuses a first health success observed after the deadline (#2020)"
  else
    fail "check_services accepted a health success after HEALTH_TIMEOUT=1 expired (status 0, out: $SVC_OUT)"
  fi
  case "$SVC_OUT" in
    *"up: org.example.test"*) fail "check_services printed 'up:' for a post-deadline success (#2020)" ;;
    *) ok "check_services prints no 'up:' line for a post-deadline success (#2020)" ;;
  esac
  case "$SVC_ERR" in
    *"not up: org.example.test"*) ok "check_services reports the late agent as not up (#2020)" ;;
    *) fail "check_services did not report the late agent as not up (stderr: $SVC_ERR)" ;;
  esac

  # Control: the same always-healthy service, well inside the
  # deadline, is accepted.
  svc_case 30
  if [ "$SVC_STATUS" -eq 0 ]; then
    ok "check_services accepts a service healthy before the deadline (#2020)"
  else
    fail "check_services refused an on-time healthy service (status $SVC_STATUS, out: $SVC_OUT, err: $SVC_ERR)"
  fi
  case "$SVC_OUT" in
    *"up: org.example.test (pid 1234)"*) ok "check_services prints 'up:' for an on-time healthy service (#2020)" ;;
    *) fail "check_services did not print the expected 'up:' line (got: $SVC_OUT)" ;;
  esac
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures simple-rebuild parser check(s) failed" >&2
  exit 1
fi
echo "all simple-rebuild parser checks passed"
