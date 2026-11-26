#!/bin/bash
# Install the launchd agent for auto-patching VSCode Insiders
# Usage: bash ~/nix/install-vscode-patch-agent.sh

usage() {
    echo "Usage: bash ~/nix/install-vscode-patch-agent.sh"
}

# This script takes no arguments (#1177): any argument was silently
# ignored and the full install (chmod, plist write, launchctl load)
# ran with exit 0. Reject the first argument by name, with usage on
# stderr and exit 2, before any install step -- the house argument
# contract (#1167 / #1145 rules 1 and 8). --help prints usage and
# exits 0 with no side effects.
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help) if [[ $# -gt 1 ]]; then echo "install-vscode-patch-agent: unexpected argument: $2" >&2; usage >&2; exit 2; fi; usage; exit 0 ;;
        *) echo "install-vscode-patch-agent: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
fi

PLIST_PATH="$HOME/Library/LaunchAgents/com.drewry.patch-vscode-insiders.plist"
PATCH_SCRIPT="$HOME/nix/patch-vscode-insiders.sh"

# Ensure patch script exists and is executable
if [ ! -f "$PATCH_SCRIPT" ]; then
  echo "ERROR: Patch script not found at $PATCH_SCRIPT"
  exit 1
fi
chmod +x "$PATCH_SCRIPT"

# Preserve the loaded agent across a failed update (#2151): until now
# the script unloaded the existing agent before it knew the directory
# could be created or the replacement plist written, so a transient
# failure left a working agent stopped. Instead: snapshot the current
# plist, stage and validate the replacement, and only then unload and
# swap. If the new load fails, restore the snapshot and reload it.
PLIST_DIR="$(dirname "$PLIST_PATH")"
PLIST_TMP="$PLIST_PATH.new.$$"
PREV_PLIST=""

cleanup_staging() {
  rm -f "$PLIST_TMP"
  if [ -n "$PREV_PLIST" ]; then
    rm -f "$PREV_PLIST"
  fi
}
trap cleanup_staging EXIT

if [ -f "$PLIST_PATH" ]; then
  if ! PREV_PLIST=$(mktemp "${TMPDIR:-/tmp}/install-vscode-patch-agent-prev.XXXXXX"); then
    echo "ERROR: Could not create a temporary snapshot of the existing plist" >&2
    exit 1
  fi
  if ! cp "$PLIST_PATH" "$PREV_PLIST"; then
    echo "ERROR: Could not snapshot the existing plist at $PLIST_PATH" >&2
    exit 1
  fi
fi

# Create the LaunchAgents directory when it is missing (a fresh account
# may not have one yet); without this the write below fails -- and until
# #945 the failure was invisible, because the script still printed the
# success banner and exited 0.
if ! mkdir -p "$PLIST_DIR"; then
  echo "ERROR: Could not create LaunchAgents directory $PLIST_DIR" >&2
  exit 1
fi

# Write the replacement plist to a staging file in the same directory
# (so the swap below is a same-filesystem rename). The heredoc is
# unquoted so $PATCH_SCRIPT expands: the plist must name the exact
# script existence-checked and chmod'd above - a hardcoded absolute
# path here once pointed the agent at a different user's home
# regardless of $HOME (#1366).
if ! cat > "$PLIST_TMP" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.drewry.patch-vscode-insiders</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PATCH_SCRIPT</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/out/vs/workbench/workbench.desktop.main.js</string>
        <string>/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/out/vs/workbench/workbench.desktop.main.css</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/patch-vscode-insiders.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/patch-vscode-insiders.log</string>
</dict>
</plist>
EOF
then
  echo "ERROR: Could not write plist to $PLIST_PATH" >&2
  exit 1
fi

# Validate the staged plist before disturbing the running agent: it
# must be non-empty and name this agent's label (and pass plutil where
# available, i.e. on the macOS hosts this installer targets).
if [ ! -s "$PLIST_TMP" ] || ! grep -q "<string>com.drewry.patch-vscode-insiders</string>" "$PLIST_TMP"; then
  echo "ERROR: Staged plist for $PLIST_PATH failed validation" >&2
  exit 1
fi
if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$PLIST_TMP" >/dev/null; then
  echo "ERROR: Staged plist for $PLIST_PATH failed plutil validation" >&2
  exit 1
fi

# The replacement is staged and validated; only now unload the current
# agent and swap the plist in.
launchctl unload "$PLIST_PATH" 2>/dev/null

if ! mv "$PLIST_TMP" "$PLIST_PATH"; then
  echo "ERROR: Could not install the staged plist to $PLIST_PATH" >&2
  if [ -n "$PREV_PLIST" ]; then
    # The previous plist is still in place (the rename failed); reload
    # the agent this update unloaded.
    if launchctl load "$PLIST_PATH"; then
      echo "ERROR: Previous agent reloaded; it was left as it was before this update" >&2
    else
      echo "ERROR: Reloading the previous agent also failed; reinstall once the filesystem problem is fixed" >&2
    fi
  fi
  exit 1
fi

# Load the agent; a failed load must not be reported as success (#945).
if ! launchctl load "$PLIST_PATH"; then
  echo "ERROR: launchctl load failed for $PLIST_PATH" >&2
  if [ -n "$PREV_PLIST" ]; then
    # Roll back: restore the previous plist and reload the agent that
    # was working before this update.
    if cp "$PREV_PLIST" "$PLIST_PATH" && launchctl load "$PLIST_PATH"; then
      echo "ERROR: Restored and reloaded the previous agent; the new plist was not installed" >&2
    else
      echo "ERROR: Rollback failed: the previous agent could not be restored and reloaded" >&2
    fi
  fi
  exit 1
fi

echo "✓ Installed and loaded com.drewry.patch-vscode-insiders"
echo "  Patch script: $PATCH_SCRIPT"
echo "  Plist: $PLIST_PATH"
echo "  Log: /tmp/patch-vscode-insiders.log"
echo ""
echo "The agent will:"
echo "  - Run at login"
echo "  - Re-patch whenever VSCode Insiders updates its JS/CSS files"
