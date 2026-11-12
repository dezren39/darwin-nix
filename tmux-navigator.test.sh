#!/usr/bin/env bash
# Tests for the vim-tmux-navigator block in homeUser.nix (#1752):
#   The block chose its Ctrl-backslash binding from a tmux_version shell
#   expansion, but tmux config assignments are never shell-evaluated, so
#   tmux_version stayed the literal '$(tmux -V | sed ...)' string (whose
#   sed pattern also demanded a stale TODO_REMOVE_THIS_BLOCK match) and
#   both bc version gates silently never fired — the C-\ root-table
#   binding was never installed. The gates now ask the shell directly
#   (if-shell -b 'tmux -V | grep ...'). This suite extracts the real
#   block from homeUser.nix, loads it in isolated tmux servers, and
#   pins the effective root key table for both version branches:
#   the host's tmux (>= 3.0 here) and a stubbed `tmux -V` = 2.9.
set -u

fail=0
say() { printf '%s\n' "$*"; }
check() { # check <label> <condition...>
  local label="$1"; shift
  if "$@"; then
    say "ok - $label"
  else
    say "FAIL - $label"
    fail=1
  fi
}

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/homeUser.nix"
[ -f "$src" ] || { say "FAIL - homeUser.nix not found next to test"; exit 1; }
command -v tmux >/dev/null 2>&1 || { say "FAIL - tmux not on PATH"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Extract the navigator block (Smart pane switching .. just before the
# copy-mode-vi bindings) and strip the Nix string's 7-space indent.
awk '/# Smart pane switching/{f=1} f{print} /bind-key -T copy-mode-vi/{if(f) exit}' "$src" \
  | sed -e '$d' -e 's/^       //' > "$tmp/navigator.conf"

check "extracted block is non-empty" test -s "$tmp/navigator.conf"
check "block no longer sets tmux_version literally" \
  bash -c "! grep -q \"tmux_version='\" '$tmp/navigator.conf'"
check "block has no TODO_REMOVE_THIS_BLOCK" \
  bash -c "! grep -q 'TODO_REMOVE_THIS_BLOCK' '$tmp/navigator.conf'"
check "homeUser.nix has no TODO_REMOVE_THIS_BLOCK anywhere" \
  bash -c "! grep -q 'TODO_REMOVE_THIS_BLOCK' '$src'"

real_tmux="$(command -v tmux)"
sock_seq=0
load_and_list() { # load_and_list <conf> <path-prefix> -> root key table on stdout
  local conf="$1" prefix="$2" sock="navtest$$-$((sock_seq+=1))"
  PATH="$prefix$PATH" tmux -L "$sock" -f "$conf" new-session -d 2>/dev/null
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    if PATH="$prefix$PATH" tmux -L "$sock" list-keys -T root 2>/dev/null | grep -Fq 'select-pane -l'; then
      break
    fi
  done
  PATH="$prefix$PATH" tmux -L "$sock" list-keys -T root 2>/dev/null
  PATH="$prefix$PATH" tmux -L "$sock" kill-server 2>/dev/null
  return 0
}

# Case 1: the host tmux version, whatever it is, must install the
# binding with the send-keys form matching its version branch.
host_keys="$(load_and_list "$tmp/navigator.conf" "")"
printf '%s\n' "$host_keys" > "$tmp/host.keys"
check "host tmux: C-\\ root binding for select-pane -l is installed" \
  grep -Fq 'select-pane -l' "$tmp/host.keys"
host_ver="$("$real_tmux" -V | awk '{print $2}')"
host_major="${host_ver%%.*}"
if [ "$host_major" -ge 3 ] 2>/dev/null; then
  check "host tmux ($host_ver >= 3.0): send-keys uses the doubled-backslash form" \
    grep -Fq 'send-keys C-\\\\"' "$tmp/host.keys"
else
  check "host tmux ($host_ver < 3.0): send-keys uses the single-backslash form" \
    grep -Fq 'send-keys C-\\"' "$tmp/host.keys"
fi

# Case 2: stub `tmux -V` to 2.9 (all other calls delegate to the real
# tmux) — the < 3.0 branch must install the binding in its form.
mkdir -p "$tmp/stubbin"
{
  printf '#!/bin/sh\n'
  printf 'if [ "$1" = "-V" ]; then echo "tmux 2.9"; exit 0; fi\n'
  printf 'exec %s "$@"\n' "$real_tmux"
} > "$tmp/stubbin/tmux"
chmod +x "$tmp/stubbin/tmux"
old_keys="$(load_and_list "$tmp/navigator.conf" "$tmp/stubbin:")"
printf '%s\n' "$old_keys" > "$tmp/old.keys"
check "stubbed tmux 2.9: C-\\ root binding for select-pane -l is installed" \
  grep -Fq 'select-pane -l' "$tmp/old.keys"
check "stubbed tmux 2.9: send-keys uses the single-backslash form" \
  grep -Fq 'send-keys C-\\"' "$tmp/old.keys"

if [ "$fail" -ne 0 ]; then
  say "tmux-navigator tests FAILED"
  exit 1
fi
say "tmux-navigator tests passed"
