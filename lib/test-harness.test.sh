#!/usr/bin/env bash
# Probe rows for the shared stat double, the resolved-interpreter stub
# rule, and the literal stub-body rule (#2078).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-harness.sh
. "$SELF_DIR/test-harness.sh"
harness_init

fail() {
  echo "FAIL: $1" >&2
  HARNESS_FAILURES=$((${HARNESS_FAILURES:-0} + 1))
}
ok() { echo "ok: $1"; }

# A by-name stub works without searching PATH for /usr/bin/env.
harness_stub named-probe 'exit 0'
expected_bash="$(command -v bash)"
actual_shebang="$(head -n 1 "$HARNESS_STUB_BIN/named-probe")"
[ "$actual_shebang" = "#!$expected_bash" ] || fail "stub shebang is not the resolved bash path"
PATH="$HARNESS_STUB_BIN" "$HARNESS_STUB_BIN/named-probe" || fail "resolved-interpreter stub did not execute by name"
ok "stub uses the resolved interpreter"

# #2078: with no ARGS the body is literal text, never a printf format —
# a date(1) format and a literal percent round-trip byte-identical into
# the stub file, and the stub still runs what it says.
harness_stub date-probe 'date +%Y-%m-%d' || fail "date-format stub was refused"
[ "$(cat "$HARNESS_STUB_BIN/date-probe")" = "$(printf '#!%s\n%s' "$expected_bash" 'date +%Y-%m-%d')" ] || fail "date-format body did not round-trip byte-identical"
"$HARNESS_STUB_BIN/date-probe" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || fail "date stub did not run its body"
ok "stub body may carry a date(1) format"
literal_body='echo "100% sure: %s %d %% back\slash"'
harness_stub literal-probe "$literal_body" || fail "literal stub was refused"
[ "$(cat "$HARNESS_STUB_BIN/literal-probe")" = "$(printf '#!%s\n%s' "$expected_bash" "$literal_body")" ] || fail "literal body did not round-trip byte-identical"
[ "$("$HARNESS_STUB_BIN/literal-probe")" = '100% sure: %s %d %% back\slash' ] || fail "literal stub did not execute its body verbatim"
ok "stub body with %s, %d, %% and a backslash is literal with no ARGS"

# With ARGS the body is a printf format, as documented.
harness_stub format-probe 'echo "hello %s, %d%% done"' world 42 || fail "format stub was refused"
[ "$("$HARNESS_STUB_BIN/format-probe")" = 'hello world, 42% done' ] || fail "format expansion with ARGS changed"
ok "stub body expands as a printf format when ARGS are supplied"

# A body whose expansion errors fails the stub and writes nothing,
# instead of writing the mangled text with rc=0 (#2078).
if harness_stub broken-probe 'date +%Y-%m-%d' unused 2>"$HARNESS_ROOT/broken-err"; then
  fail "a body with an invalid format directive was accepted"
fi
[ ! -e "$HARNESS_STUB_BIN/broken-probe" ] || fail "a failed expansion still wrote a stub"
ok "a failing printf expansion fails the stub and writes nothing"

fixture="$HARNESS_ROOT/file with spaces"
printf 'fixture\n' >"$fixture"
touch -d '2020-01-02 03:04:05' "$fixture"
real_stat="$(command -v stat)"
real_mtime="$("$real_stat" -c '%Y' "$fixture")"
real_uid="$("$real_stat" -c '%u' "$fixture")"
harness_stat_double_begin || fail "stat double did not start"
[ "$(stat -f '%m' "$fixture")" = "$real_mtime" ] || fail "-f %m did not return the mtime epoch"
ok "BSD %m maps to the file mtime"
[ "$(stat -f '%u' "$fixture")" = "$real_uid" ] || fail "-f %u did not return the owner id"
ok "BSD %u maps to the file owner"
[ "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$fixture")" = '2020-01-02 03:04:05' ] || fail "-f %Sm did not format the modified date"
ok "BSD %Sm formats the modified date"
birth_date="$(stat -f '%SB' -t '%Y-%m-%d' "$fixture")"
case "$birth_date" in ????-??-??) ok "BSD %SB returns a date" ;; *) fail "-f %SB returned an invalid date: $birth_date" ;; esac
if stat -c '%Y' "$fixture" >"$HARNESS_ROOT/stat-out" 2>"$HARNESS_ROOT/stat-err"; then
  fail "GNU -c was accepted by the BSD stat double"
else
  grep -q 'illegal option -- c' "$HARNESS_ROOT/stat-err" || fail "-c refusal did not name the unsupported option"
fi
ok "GNU -c is rejected"
if stat -f '%unsupported' "$fixture" >"$HARNESS_ROOT/stat-out" 2>"$HARNESS_ROOT/stat-err"; then
  fail "unsupported BSD format was accepted"
else
  grep -q 'unsupported -f format' "$HARNESS_ROOT/stat-err" || fail "unsupported format refusal was not explained"
fi
ok "unsupported BSD formats are rejected"
harness_stat_double_end
harness_summary
