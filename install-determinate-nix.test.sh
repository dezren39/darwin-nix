#!/usr/bin/env bash
# Regression test for install-determinate-nix's argument validation (#1804).
#
# The script documents one optional [HOSTNAME] positional but used to read
# only $1 and never validate the rest: a stray second argument such as
# --help was silently ignored while the script installed Nix, rewrote all
# three hostname keys, deleted /etc/nix/nix.custom.conf, adopted the host,
# and switched the system. The parse segment now rejects extra arguments
# and flag-shaped hostnames with the offending argument, usage, and exit 2,
# and gives -h/--help a no-side-effect usage path (exit 0) — all before the
# default-hostname scutil lookup, the first subprocess the script runs.
#
# This suite cannot drive the real script end to end (a valid control
# would install Nix and switch a real system), so it extracts the REAL
# parse segment from install-determinate-nix — from `install_usage()`
# through the end-of-parse marker comment — and runs that segment under
# zsh, the script's interpreter, with scutil stubbed to log its calls.
# Nothing is a pasted copy: if the shipped parser changes, the extracted
# segment changes with it, and a missing marker fails here.
#
# Oracle per case: exit status, the stderr/stdout text named in the
# assertions, and the stub log — an invalid invocation must record ZERO
# scutil calls; a valid explicit hostname must record zero too (no lookup
# is needed); a valid default invocation records exactly the one
# `scutil --get LocalHostName` lookup and yields the stubbed name.
#
# Run: ./install-determinate-nix.test.sh
# It is run by the flake check `install-determinate-nix-tests`.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/install-determinate-nix"

command -v zsh >/dev/null || { echo "zsh required" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $1"; }

# Extract the parse segment from the real script.
SEGMENT="$TMP_ROOT/parse.zsh"
awk '/^install_usage\(\)/{f=1} /^# End of parse-time validation/{f=0} f' "$SCRIPT" >"$SEGMENT"
[ -s "$SEGMENT" ] || { echo "could not extract parse segment from install-determinate-nix" >&2; exit 1; }
grep -q 'unexpected argument' "$SEGMENT" || fail "extracted segment lacks the #1804 extra-argument guard"
grep -q 'unknown option' "$SEGMENT" || fail "extracted segment lacks the #1804 flag-shaped hostname guard"
get_seg_count="$(grep -c 'scutil --get LocalHostName' "$SEGMENT")"
[ "$get_seg_count" -eq 1 ] || fail "expected exactly one scutil --get LocalHostName inside the parse segment, found $get_seg_count"

# --- Ordering pins (#1804): validation precedes every side effect ---
line_of() { grep -n -m1 -- "$1" "$SCRIPT" | cut -d: -f1; }
seg_line_of() { grep -n -m1 -- "$1" "$SEGMENT" | cut -d: -f1; }
parse_line="$(line_of '^install_usage()')"
curl_line="$(line_of 'curl --fail')"
installer_line="$(line_of 'sudo installer')"
set_line="$(line_of 'sudo scutil --set')"
adopt_line="$(line_of '/adopt" --host')"
exec_line="$(line_of '^exec ./s')"
extra_seg_line="$(seg_line_of 'unexpected argument')"
option_seg_line="$(seg_line_of 'unknown option')"
host_seg_line="$(seg_line_of '^host=')"
if [ -n "$parse_line" ] && [ -n "$curl_line" ] && [ -n "$installer_line" ] && [ -n "$set_line" ] \
  && [ -n "$adopt_line" ] && [ -n "$exec_line" ] \
  && [ "$parse_line" -lt "$curl_line" ] && [ "$parse_line" -lt "$installer_line" ] \
  && [ "$parse_line" -lt "$set_line" ] && [ "$parse_line" -lt "$adopt_line" ] \
  && [ "$parse_line" -lt "$exec_line" ] \
  && [ -n "$extra_seg_line" ] && [ -n "$option_seg_line" ] && [ -n "$host_seg_line" ] \
  && [ "$extra_seg_line" -lt "$host_seg_line" ] && [ "$option_seg_line" -lt "$host_seg_line" ]; then
  ok "argument validation precedes curl/installer/scutil --set/adopt/exec and the default-hostname lookup (#1804)"
else
  fail "ordering pin (#1804): parse=$parse_line curl=$curl_line installer=$installer_line set=$set_line adopt=$adopt_line exec=$exec_line extra=$extra_seg_line option=$option_seg_line host=$host_seg_line"
fi

export STUB_LOG="$TMP_ROOT/stub.log"
export SEGMENT

PROBE="$TMP_ROOT/probe.zsh"
cat >"$PROBE" <<'EOF'
#!/usr/bin/env zsh
scutil() { print -r -- "scutil $*" >> "$STUB_LOG"; echo StubLocalName; }
source "$SEGMENT" "$@"
echo "host=$host"
EOF

run() { # run <args...> -- sets OUT, ERR, STATUS, STUB
  : >"$STUB_LOG"
  OUT="$(zsh "$PROBE" "$@" 2>"$TMP_ROOT/err")"; STATUS=$?
  ERR="$(cat "$TMP_ROOT/err")"
  STUB="$(cat "$STUB_LOG")"
}

expect_reject() { # expect_reject <label> <needle> <args...>
  local label="$1" needle="$2"; shift 2
  run "$@"
  [ "$STATUS" -eq 2 ] || { fail "$label exited $STATUS (want 2)"; return; }
  case "$ERR" in *"$needle"*) ;; *) fail "$label stderr lacks '$needle': $ERR"; return;; esac
  case "$ERR" in *"usage: install-determinate-nix"*) ;; *) fail "$label stderr lacks usage: $ERR"; return;; esac
  [ -z "$STUB" ] || { fail "$label called stubs: $STUB"; return; }
  case "$OUT" in *"host="*) fail "$label reached host assignment: $OUT"; return;; esac
  ok "$label"
}

expect_help() { # expect_help <label> <args...>
  local label="$1"; shift
  run "$@"
  [ "$STATUS" -eq 0 ] || { fail "$label exited $STATUS (want 0)"; return; }
  case "$OUT" in *"usage: install-determinate-nix [HOSTNAME]"*) ;; *) fail "$label stdout lacks usage: $OUT"; return;; esac
  [ -z "$STUB" ] || { fail "$label called stubs: $STUB"; return; }
  ok "$label"
}

expect_reject "extra argument after hostname" "unexpected argument: extra" myhost extra
expect_reject "stray --help after hostname (the #1804 case)" "unexpected argument: --help" myhost --help
expect_reject "flag-shaped hostname" "unknown option: --bogus" --bogus
expect_reject "--help with an extra argument" "unexpected argument: extra" --help extra
expect_help "--help alone prints usage, no side effects" --help
expect_help "-h alone prints usage, no side effects" -h

run myhost
if [ "$STATUS" -eq 0 ] && [ "$OUT" = "host=myhost" ] && [ -z "$STUB" ]; then
  ok "valid explicit hostname: host=myhost, scutil never called"
else
  fail "valid explicit hostname: status=$STATUS out='$OUT' stub='$STUB'"
fi

run
if [ "$STATUS" -eq 0 ] && [ "$OUT" = "host=StubLocalName" ] && [ "$STUB" = "scutil --get LocalHostName" ]; then
  ok "valid default hostname: one stubbed scutil lookup yields StubLocalName"
else
  fail "valid default hostname: status=$STATUS out='$OUT' stub='$STUB'"
fi

# --- Temp-dir cleanup (#1821): success + both failure paths -----------
# The install block used to rm only the pkg file on success and, under
# set -e, nothing at all when curl or installer failed -- the mktemp
# directory (and a partial or full pkg) leaked in ${TMPDIR}. The block
# now traps EXIT to rm -rf the directory it created, and clears the
# trap after an explicit cleanup on success (the script later execs
# ./s, across which a trap would not run).
#
# Same extraction discipline as the parse segment above: the REAL
# install segment (from `url=` through the block's closing `fi`) is
# extracted from the shipped script and run under zsh with mktemp,
# curl, installer (via a sudo pass-through) stubbed. The only edit to
# the extracted text substitutes the hard-coded nix profile path with
# a path that never exists, so the install branch runs on any machine.
# Oracle per case: exit status (the original curl/installer status,
# unmasked), the stub log, and the stub temp directory being GONE.
SEGMENT2="$TMP_ROOT/install.zsh"
awk '/^url=/{f=1} f{print} f&&/^fi$/{exit}' "$SCRIPT" \
  | sed "s|/nix/var/nix/profiles/default/bin/nix|$TMP_ROOT/no-nix-here|g" >"$SEGMENT2"
[ -s "$SEGMENT2" ] || { echo "could not extract install segment from install-determinate-nix" >&2; exit 1; }
grep -q 'mktemp -d' "$SEGMENT2" || fail "extracted install segment lacks the mktemp -d call"
grep -q "trap 'rm -rf" "$SEGMENT2" || fail "extracted install segment lacks the #1821 cleanup trap"

PROBE2="$TMP_ROOT/probe2.zsh"
cat >"$PROBE2" <<'EOF'
#!/usr/bin/env zsh
set -eu
mktemp() { mkdir -p "$TEST_TMP/stubtmpdir"; print -r -- "$TEST_TMP/stubtmpdir"; }
curl() {
  local out=""
  while (( $# > 0 )); do
    case "$1" in
      --output) out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  print -r -- "curl output=$out" >> "$STUB_LOG"
  print -r -- "partial-pkg" > "$out"
  if [[ "$MODE" == curlfail ]]; then exit 22; fi
}
installer() {
  print -r -- "installer $*" >> "$STUB_LOG"
  if [[ "$MODE" == installerfail ]]; then exit 1; fi
}
sudo() { "$@"; }
source "$SEG2"
echo "segment-ok"
EOF

run_install_case() { # run_install_case <mode> -- sets OUT, STATUS, STUB
  local mode="$1"
  rm -rf "$TMP_ROOT/case"; mkdir -p "$TMP_ROOT/case"
  : >"$STUB_LOG"
  OUT="$(MODE="$mode" TEST_TMP="$TMP_ROOT/case" STUB_LOG="$STUB_LOG" SEG2="$SEGMENT2" zsh "$PROBE2" 2>&1)"; STATUS=$?
  STUB="$(cat "$STUB_LOG")"
}

before=$failures
run_install_case success
[ "$STATUS" -eq 0 ] || fail "install success case exited $STATUS (want 0): $OUT"
case "$OUT" in *"segment-ok"*) ;; *) fail "install success case did not complete the segment: $OUT" ;; esac
case "$STUB" in *"installer -pkg $TMP_ROOT/case/stubtmpdir/determinate-nix.pkg -target /"*) ;; *) fail "install success case: installer not called with the stub pkg: $STUB" ;; esac
[ ! -e "$TMP_ROOT/case/stubtmpdir" ] || fail "install success case left the temp directory behind"
[ "$failures" -eq "$before" ] && ok "install success: pkg installed, temp directory removed (#1821)"

before=$failures
run_install_case curlfail
[ "$STATUS" -eq 22 ] || fail "curl failure case exited $STATUS (want 22, the original curl status): $OUT"
[ ! -e "$TMP_ROOT/case/stubtmpdir" ] || fail "curl failure case left the temp directory (and partial pkg) behind"
[ "$failures" -eq "$before" ] && ok "curl failure: exit 22 preserved, temp directory and partial pkg removed (#1821)"

before=$failures
run_install_case installerfail
[ "$STATUS" -eq 1 ] || fail "installer failure case exited $STATUS (want 1, the original installer status): $OUT"
[ ! -e "$TMP_ROOT/case/stubtmpdir" ] || fail "installer failure case left the temp directory behind"
[ "$failures" -eq "$before" ] && ok "installer failure: exit 1 preserved, temp directory removed (#1821)"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all install-determinate-nix argument tests passed"
