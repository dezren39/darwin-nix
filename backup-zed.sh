#!/usr/bin/env zsh

# This script takes no arguments (#1167): any argument was silently
# ignored and the full backup ran with exit 0. Reject the first
# argument by name, with usage on stderr and exit 2, before any
# copy -- the house argument contract (#1145 rules 1 and 8).
# --help prints usage and exits 0, with no side effects.
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help) if [[ $# -gt 1 ]]; then echo "backup-zed: unexpected argument: $2" >&2; echo "Usage: backup-zed.sh" >&2; exit 2; fi; echo "Usage: backup-zed.sh"; exit 0 ;;
        *) echo "backup-zed: unknown argument: $1" >&2; echo "Usage: backup-zed.sh" >&2; exit 2 ;;
    esac
fi

path=("$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin" "/run/current-system/sw/bin" "$path[@]")
set -exuo pipefail
#ulimit -n $(ulimit -Hn)
#sudo prlimit --pid $$ --nofile=1000000:1000000
#nix-shell -p nixVersions.nix_2_18 git cachix jq
#cat /mnt/c/wsl/cachix.key | cachix authtoken --stdin
# Get the directory of the script. `${BASH_SOURCE[0]}` does not exist under
# this zsh shebang: with `set -u` it errored inside the command substitution,
# script_dir came out empty and `cd ''` silently stayed in the caller's
# directory. Same fix as rebuild.sh/simple-rebuild.sh: :A resolves symlinks,
# :h takes the dirname.
script_dir="${0:A:h}"
# Git add for the script's directory
cd "${script_dir}" || exit 1
echo "entered: $script_dir"

# Publish the three-file snapshot coherently (#1787). The copies used to
# land sequentially, so a failure midway (a missing index, a failed find)
# left a mixed old/new snapshot behind a nonzero exit. Now every output
# is staged to a temp file in ./.zed/ first (same directory, so each
# publish rename is atomic per file) and the snapshot is published only
# after all three stages succeed. Three renames are NOT atomic as a
# group, so publishing first copies each prior output aside and rolls
# the already-published files back if a rename fails, reporting the
# failure explicitly instead of leaving the mix in place.
settings_src="$HOME/.config/zed/settings.json"
index_src="$HOME/Library/Application Support/Zed/extensions/index.json"
installed_src="$HOME/Library/Application Support/Zed/extensions/installed"

settings_tmp=$(mktemp ./.zed/.settings.json.XXXXXX)
index_tmp=$(mktemp ./.zed/.index.json.XXXXXX)
installed_tmp=$(mktemp ./.zed/.installed.txt.XXXXXX)
settings_bak=$(mktemp ./.zed/.settings.json.bak.XXXXXX)
index_bak=$(mktemp ./.zed/.index.json.bak.XXXXXX)
installed_bak=$(mktemp ./.zed/.installed.txt.bak.XXXXXX)
trap 'rm -f "$settings_tmp" "$index_tmp" "$installed_tmp" "$settings_bak" "$index_bak" "$installed_bak"' EXIT

cp -f "$settings_src" "$settings_tmp" || {
    echo "backup-zed: cannot read settings source: $settings_src" >&2
    exit 1
}
cp -f "$index_src" "$index_tmp" || {
    echo "backup-zed: cannot read extensions index source: $index_src" >&2
    exit 1
}
# Sort the list (#946): raw find order is readdir order, so the committed
# snapshot reshuffled between runs. LC_ALL=C sort makes regeneration
# byte-identical when nothing changed; pipefail makes a failed find fail
# the pipeline, so the enumeration failure is caught here and nothing
# publishes (the #860 guarantee, now extended to all three outputs).
find "$installed_src" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort > "$installed_tmp" || {
    echo "backup-zed: cannot enumerate installed extensions: $installed_src" >&2
    exit 1
}

# Copy the prior outputs aside for rollback. A destination that does not
# exist yet is recorded as absent, so rollback removes a first publish
# instead of resurrecting a stale backup copy.
had_settings=0
had_index=0
had_installed=0
if [[ -e ./.zed/settings.json ]]; then
    cp -f ./.zed/settings.json "$settings_bak" && had_settings=1
fi
if [[ -e ./.zed/index.json ]]; then
    cp -f ./.zed/index.json "$index_bak" && had_index=1
fi
if [[ -e ./.zed/installed.txt ]]; then
    cp -f ./.zed/installed.txt "$installed_bak" && had_installed=1
fi

published_settings=0
published_index=0
publish_failed=0
mv -f "$settings_tmp" ./.zed/settings.json || publish_failed=1
if [[ $publish_failed -eq 0 ]]; then
    published_settings=1
    mv -f "$index_tmp" ./.zed/index.json || publish_failed=1
fi
if [[ $publish_failed -eq 0 ]]; then
    published_index=1
    mv -f "$installed_tmp" ./.zed/installed.txt || publish_failed=1
fi

if [[ $publish_failed -ne 0 ]]; then
    # A publish rename failed partway: restore whichever outputs were
    # already replaced so the snapshot is the prior one, not a mix.
    if [[ $published_settings -eq 1 ]]; then
        if [[ $had_settings -eq 1 ]]; then
            cp -f "$settings_bak" ./.zed/settings.json || true
        else
            rm -f ./.zed/settings.json
        fi
    fi
    if [[ $published_index -eq 1 ]]; then
        if [[ $had_index -eq 1 ]]; then
            cp -f "$index_bak" ./.zed/index.json || true
        else
            rm -f ./.zed/index.json
        fi
    fi
    echo "backup-zed: publishing the snapshot failed; prior snapshot restored" >&2
    exit 1
fi

rm -f "$settings_bak" "$index_bak" "$installed_bak"
trap - EXIT
