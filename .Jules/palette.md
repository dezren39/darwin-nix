# Palette's journal — critical UX / accessibility learnings only

## 2026-11-24 - Terminal diagnostics: a refusal is only done when stdout is empty

**Learning:** The user-facing surface of this repo is the terminal, so "error
display" is a real UX concern. A parse-time refusal that exits 2 but emits its
explanatory hint on stdout (`git-maintain-repos --system --quick`, #1926) is
worse than no hint at all: the caller's pipe or log picks up an orphan fragment
while the error line went to stderr, so the two halves split across streams and
the run reads as both failed and half-succeeded. The family contract in
`lib/common.sh` (examples in `clean.sh`: caches/logs only and opens no
repository) is: program-prefixed line on stderr, continuation wrapped in
parentheses indented to the program prefix width + 2 (20 cols for
`git-maintain-repos: `), and nothing on stdout.

**Action:** When working on any `arg_die` / `arg_refuse_in_mode` / conflict
judge, check the stream of *every* line of the message, not just the first, and
pin `[ -z "$OUT" ]` plus the exact indented hint in the suite. Prefer the shared
`arg_refuse_in_mode` helper over hand-rolled echoes (it already gets streams
and indentation right) — `git-maintain-repos` is now the last script still
hand-rolling that block.
