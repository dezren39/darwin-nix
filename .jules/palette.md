# Palette journal

## 2026-11-04 - Color output gating was per-script and incomplete
**Learning:** This repo's user-facing shell scripts each invented their own
ANSI color handling: opencode-share gated on a tty but ignored NO_COLOR,
brew-repair and clean.sh colored unconditionally (raw escapes landed in
piped/logged output), and full-clean bolded its step headers the same way.
**Action:** When touching terminal UX here, apply the one house gate --
colors only when that output stream is a terminal and `NO_COLOR` is unset --
to every script that emits escapes, as a set, not just the one in front of you.

## 2026-11-22 - The script layer is fully dispositioned; check the front door
**Learning:** Every top-level and `pkgs/**` shell script here already has a
recorded disposition against the house argument contract and the NO_COLOR
gate (docs/2026-11-08-mode-effectiveness-inventory.md, the 2026-11-16/17
polish wave, and the Palette PRs since). The unpolished surface was the
README itself: a 10-line stub naming none of the daily commands or the
maintained orientation docs (ARCHITECTURE.md, ROADMAP.md, planning/).
**Action:** On future Palette runs here, check front-door/docs surfaces
first; re-survey scripts only for ones added since the inventory.
