#!/usr/bin/env bash

# Find applications that weren't installed through Homebrew
# Compares /Applications and ~/Applications against brew list
# Outputs applications that don't match any Homebrew installation

set -euo pipefail

usage() {
    echo "Usage: search.sh"
}

# This script takes no arguments (#1158): any argument was silently
# ignored and the full scan ran with exit 0. Reject the first argument
# by name, with usage on stderr and exit 2, before any brew call --
# the house argument contract. --help prints usage and exits 0.
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) echo "search: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
fi

# Get list of all Homebrew-installed apps. Capture `brew list --cask`
# once, with its exit status checked (#957): the old process
# substitutions hid a failed `brew list` — its status was invisible
# and its stderr discarded by 2>/dev/null — so brew breakage (or a
# missing brew) looked exactly like "no casks installed" and every
# app was reported as not brew-installed, with exit 0. Name the
# failing step on stderr, surface brew's own stderr, and exit 1.
# A genuinely empty successful list keeps the normal path below.
BREW_ERR=$(mktemp)
INFO_ERR=$(mktemp)
UNMANAGED_APPS_FILE=$(mktemp)
trap 'rm -f "$BREW_ERR" "$INFO_ERR" "$UNMANAGED_APPS_FILE"' EXIT

if ! BREW_LIST=$(brew list --cask 2>"$BREW_ERR"); then
    echo "search: error: 'brew list --cask' failed — installed casks could not be enumerated" >&2
    if [[ -s "$BREW_ERR" ]]; then
        sed 's/^/  /' "$BREW_ERR" >&2
    fi
    exit 1
fi

# The token list alone cannot say which apps are brew-installed
# (#1779): a cask token need not equal its installed bundle name
# (`iterm2` installs `iTerm.app`), so comparing tokens with bundle
# names both misses renamed bundles and falsely clears unrelated
# bundles that happen to match a token. Ask brew for the installed
# casks' actual app artifacts instead -- `brew info --json=v2
# --cask`, the same one-shot scan brew-repair uses -- and compare
# against those. The scan is part of the enumeration, so it gets
# the #957 treatment too: a failed `brew info`, unparseable output,
# or no cask data for a non-empty token list names the step on
# stderr and exits 1 rather than silently claiming a complete
# inventory. An empty token list skips the scan entirely (the
# empty-list behaviour below is unchanged: everything found is
# reported).
BREW_APPS=()
BREW_NAMES=()
if [[ -n "$BREW_LIST" ]]; then
    TOKENS=()
    while IFS= read -r token; do
        TOKENS+=("$token")
    done < <(printf '%s\n' "$BREW_LIST")

    if ! BREW_INFO=$(brew info --json=v2 --cask "${TOKENS[@]}" 2>"$INFO_ERR"); then
        echo "search: error: 'brew info --cask' failed -- installed cask artifacts could not be enumerated" >&2
        if [[ -s "$INFO_ERR" ]]; then
            sed 's/^/  /' "$INFO_ERR" >&2
        fi
        exit 1
    fi

    # One line per installed app artifact: "<lower>|<normalized>",
    # the two forms check_if_brew_installed compares against. An
    # app artifact's list is [source, ..., {options}]: a 'target'
    # option renames the installed bundle, so the target's basename
    # is the app that exists on disk -- the source name does not
    # (#1497). Without a target, every string element is an
    # installed app. Exit 2 from the parser means brew returned no
    # cask data at all for a non-empty token list: an enumeration
    # failure, reported like the others, never an empty inventory.
    if ! ARTIFACT_NAMES=$(printf '%s' "$BREW_INFO" | python3 -c "
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
casks = data.get('casks')
if not isinstance(casks, list) or not casks:
    sys.exit(2)
for c in casks:
    for a in c.get('artifacts', []):
        if isinstance(a, dict) and 'app' in a:
            elements = a['app'] if isinstance(a['app'], list) else [a['app']]
            targets = [os.path.basename(e['target']) for e in elements
                       if isinstance(e, dict) and isinstance(e.get('target'), str)]
            apps = targets if targets else [e for e in elements if isinstance(e, str)]
            for app in apps:
                base = os.path.basename(app)
                if base.lower().endswith('.app'):
                    base = base[:-4]
                lower = base.lower()
                print(lower + '|' + lower.replace(' ', '-').replace('.', '-'))
"); then
        echo "search: error: could not parse 'brew info --cask' output -- installed cask artifacts could not be enumerated" >&2
        exit 1
    fi

    # Read into arrays with Bash 3.2-compatible loops. `mapfile` was added
    # in Bash 4, while macOS's system `/usr/bin/env bash` is still 3.2.
    if [[ -n "$ARTIFACT_NAMES" ]]; then
        while IFS='|' read -r lower normalized; do
            BREW_APPS+=("$lower")
            BREW_NAMES+=("$normalized")
        done < <(printf '%s\n' "$ARTIFACT_NAMES")
    fi
fi

check_if_brew_installed() {
    local app_path="$1"
    local app_name
    local normalized_name

    # Skip if not an app
    if [[ ! "$app_path" =~ \.app$ ]]; then
        return
    fi

    # Get the app name without .app extension
    app_name=$(basename "$app_path" .app | tr '[:upper:]' '[:lower:]')
    normalized_name=$(echo "$app_name" | tr ' .' '-')

    # Check if app exists in brew list
    if [[ ! " ${BREW_APPS[*]} " =~ " ${app_name} " ]] && \
       [[ ! " ${BREW_NAMES[*]} " =~ " ${normalized_name} " ]]; then
        # echo "${app_path}"
        echo "${normalized_name}"
        printf '%s\n' "$normalized_name" >> "$UNMANAGED_APPS_FILE"

        # echo
    fi
}

# First leg scans /Applications; SEARCH_APPLICATIONS_DIR overrides the
# directory for tests (#983) — the default behaviour is unchanged.
# A missing first-leg directory is NOT fatal (#1255): it gets the same
# treatment as the ~/Applications leg below — a plain "does not exist"
# notice, then the remaining leg still runs and the script exits 0.
# (Contrast #957 above: a failed `brew list` is fatal because without
# it no comparison is possible at all; a missing scan directory only
# empties one of the two scan sources.)
APPLICATIONS_DIR="${SEARCH_APPLICATIONS_DIR:-/Applications}"
echo "Checking $APPLICATIONS_DIR..."
if [ -d "$APPLICATIONS_DIR" ]; then
    find "$APPLICATIONS_DIR" -maxdepth 1 -name "*.app" -print0 | while IFS= read -r -d '' app; do
        check_if_brew_installed "$app"
    done
else
    echo "$APPLICATIONS_DIR directory does not exist"
fi

echo "Checking ~/Applications..."
if [ -d ~/Applications ]; then
    find ~/Applications -maxdepth 1 -name "*.app" -print0 | while IFS= read -r -d '' app; do
        check_if_brew_installed "$app"
    done
else
    echo "~/Applications directory does not exist"
fi

if [[ ! -s "$UNMANAGED_APPS_FILE" ]]; then
    echo "No non-Homebrew apps found."
fi
