#!/usr/bin/env bash
# brew-adopt-unmanaged.sh — bring apps that already exist on this machine
# outside brew's management under brew, before `brew bundle` runs (#1791).
#
# Two apps arrived on this machine outside brew, and `brew bundle` reads
# both as "missing" on every activation:
#
#   google-chrome — the bundle at /Applications/Google Chrome.app is
#   root-owned (delivered outside brew). Brew stages the cask download
#   over it and dies: `chgrp: /Applications/Google Chrome.app/...:
#   Operation not permitted` on every file, then the failed bundle fails
#   darwin-rebuild activation (2026-11-11 run: cask 157.0.8103.51 over
#   installed 157.0.8103.40). Fix applied here, in order:
#     1. `chown -R` the bundle to the primary user. The profile is NOT in
#        the bundle — it lives in ~/Library/Application Support/Google/
#        Chrome — so this touches only the application itself, and it is
#        the ownership every brew-installed Chrome has. Keystone (the
#        /Library/Google updater daemon) updates a user-owned bundle the
#        same as a root-owned one.
#     2. `brew install --cask --adopt google-chrome`. Per brew's source
#        (cask/artifact/moved.rb), --adopt keeps the existing bundle and
#        only writes brew's Caskroom receipt; for `auto_updates` casks
#        like this one it skips the bundle-version comparison entirely,
#        so adopting 157.0.8103.40 against cask 157.0.8103.51 is fine —
#        Keystone keeps the app itself current either way.
#     3. If --adopt fails, fall back to `brew install --cask --force`
#        over the now user-owned bundle (the ordinary reinstall path;
#        it could not work while the bundle was root-owned).
#   If the chown cannot make the bundle user-owned, this script exits 1
#   BEFORE bundle runs, with the remedy in plain words — a clear failure
#   instead of brew's wall of chgrp errors.
#
#   onedrive — the installed 26.198.1011.0006 (Microsoft's Production
#   ring, rolling out 2026-10-30) is newer than the upstream cask
#   (26.189.0928.0009 — homebrew-cask tracks the Deferred ring via
#   fwlink 823060), and brew has no receipt for it, so bundle runs the
#   cask's pkg and the installer refuses the downgrade: "A newer version
#   of OneDrive is already installed". `--adopt` cannot help here:
#   brew's Pkg artifact ignores the flag (cask/artifact/pkg.rb accepts
#   the parameter and never uses it) — adoption-by-receipt only exists
#   for Moved (app) artifacts. So the repo vendors the cask at the
#   installed version (homebrew-local/Casks/onedrive.rb, tap
#   dezren39/homebrew-local): installing the vendored pkg is a
#   same-version install, which the macOS installer allows, and it
#   writes brew's receipt — brew owns OneDrive from then on, and the
#   app keeps self-updating (auto_updates). This script's job for
#   OneDrive is the guard rail: if the app has self-updated PAST the
#   vendored version before the first adoption, the vendored pkg would
#   be a downgrade again — exit 1 before bundle, naming the exact
#   state and the one-line remedy. It also logs the retirement
#   tripwire: once the upstream cask reaches the vendored version,
#   homebrew-local can be deleted and casks.nix switched back to the
#   plain "onedrive".
#
# Runs as root from system.activationScripts.homebrew (the order-600
# text in configuration.nix: after nix-homebrew's setup at 500, before
# nix-darwin's bundle text at 1000). Brew itself is invoked as the primary user, like the macfuse
# block in configuration.nix. Every step logs what it did and why.
#
# Env overrides exist for the test file (brew-adopt-unmanaged.test.sh):
# BREW_ADOPT_BREW, BREW_ADOPT_SUDO, BREW_ADOPT_PLISTBUDDY,
# BREW_ADOPT_APPLICATIONS, BREW_ADOPT_TAPS_DIR, BREW_ADOPT_PATH.
set -uo pipefail
PATH=${BREW_ADOPT_PATH:-/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin}

PRIMARY_USER=${1:?usage: brew-adopt-unmanaged.sh PRIMARY_USER}
BREW=${BREW_ADOPT_BREW:-/opt/homebrew/bin/brew}
SUDO=${BREW_ADOPT_SUDO:-/usr/bin/sudo}
PLISTBUDDY=${BREW_ADOPT_PLISTBUDDY:-/usr/libexec/PlistBuddy}
APPLICATIONS=${BREW_ADOPT_APPLICATIONS:-/Applications}
TAPS_DIR=${BREW_ADOPT_TAPS_DIR:-/opt/homebrew/Library/Taps}

log() { echo "brew-adopt-unmanaged: $*" >&2; }

as_user() { "$SUDO" --user="$PRIMARY_USER" --set-home "$@"; }

brew_has_cask() {
  as_user env HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" list --cask "$1" >/dev/null 2>&1
}

# Echo the `version "X"` of a cask file ($1); empty when unreadable.
cask_version() {
  [ -f "$1" ] || return 0
  sed -n 's/^[[:space:]]*version "\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# Dotted-numeric version compare: echoes -1, 0 or 1 for $1 <, =, > $2.
# Missing trailing components count as 0 (26.198.1011 = 26.198.1011.0).
vercmp() {
  local a b x y i
  local IFS=.
  # shellcheck disable=SC2206
  a=($1)
  # shellcheck disable=SC2206
  b=($2)
  for i in 0 1 2 3; do
    x=${a[i]:-0}
    y=${b[i]:-0}
    x=${x//[!0-9]/}
    y=${y//[!0-9]/}
    x=$((10#${x:-0}))
    y=$((10#${y:-0}))
    if ((x < y)); then
      echo -1
      return
    fi
    if ((x > y)); then
      echo 1
      return
    fi
  done
  echo 0
}

# ---------------------------------------------------------------- chrome
chrome_app="$APPLICATIONS/Google Chrome.app"
if [ -d "$chrome_app" ]; then
  owner=$(stat -f %Su "$chrome_app")
  if [ "$owner" != "$PRIMARY_USER" ]; then
    log "google-chrome: $chrome_app is owned by '$owner', not $PRIMARY_USER — brew cannot replace a bundle it does not own (#1791). Taking ownership: chown -R $PRIMARY_USER \"$chrome_app\""
    chown -R "$PRIMARY_USER" "$chrome_app" || true
    owner=$(stat -f %Su "$chrome_app")
    if [ "$owner" = "$PRIMARY_USER" ]; then
      log "google-chrome: bundle now owned by $PRIMARY_USER (profile data in ~/Library/Application Support/Google/Chrome is untouched — it was never in the bundle)"
    else
      log "ERROR: could not take ownership of $chrome_app (still owned by '$owner')."
      log "ERROR: remedy: sudo chown -R $PRIMARY_USER \"$chrome_app\" — then re-run ./s."
      log "ERROR: aborting before brew bundle so the failure is this message, not brew's chgrp errors."
      exit 1
    fi
  else
    log "google-chrome: bundle already owned by $PRIMARY_USER"
  fi

  if brew_has_cask google-chrome; then
    log "google-chrome: already brew-managed (Caskroom receipt present); nothing to adopt"
  else
    log "google-chrome: no brew receipt — adopting the existing bundle: brew install --cask --adopt google-chrome (auto_updates cask: brew records the receipt without touching the bundle)"
    if as_user env HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" install --cask --adopt google-chrome; then
      log "google-chrome: adopted — brew now manages the existing bundle"
    else
      log "google-chrome: --adopt failed; falling back to a full install over the now user-owned bundle: brew install --cask --force google-chrome"
      if as_user env HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" install --cask --force google-chrome; then
        log "google-chrome: installed by brew over the existing bundle; now brew-managed"
      else
        log "WARNING: google-chrome adoption and the fallback install both failed."
        log "WARNING: the bundle is user-owned now, so the root-owned chgrp failure cannot come back; if brew bundle still fails on google-chrome, run: brew install --cask --force google-chrome"
      fi
    fi
  fi
else
  log "google-chrome: no bundle at $chrome_app; brew bundle will install it fresh"
fi

# --------------------------------------------------------------- onedrive
vendored_file="$TAPS_DIR/dezren39/homebrew-local/Casks/onedrive.rb"
upstream_file="$TAPS_DIR/homebrew/homebrew-cask/Casks/o/onedrive.rb"
vendored_version=$(cask_version "$vendored_file")
upstream_version=$(cask_version "$upstream_file")
if [ -n "$vendored_version" ] && [ -n "$upstream_version" ] &&
  [ "$(vercmp "$upstream_version" "$vendored_version")" != "-1" ]; then
  log "onedrive: upstream cask ($upstream_version) has caught up with the vendored cask ($vendored_version) — retire homebrew-local and switch casks.nix back to plain \"onedrive\" (#1791)"
fi

if brew_has_cask dezren39/local/onedrive; then
  log "onedrive: already brew-managed via the vendored cask (dezren39/local/onedrive); nothing to do"
elif [ -d "$APPLICATIONS/OneDrive.app" ]; then
  installed_version=$("$PLISTBUDDY" -c "Print :CFBundleVersion" "$APPLICATIONS/OneDrive.app/Contents/Info.plist" 2>/dev/null || true)
  if [ -z "$installed_version" ]; then
    installed_version=$("$PLISTBUDDY" -c "Print :CFBundleShortVersionString" "$APPLICATIONS/OneDrive.app/Contents/Info.plist" 2>/dev/null || true)
  fi
  if [ -z "$installed_version" ]; then
    log "ERROR: OneDrive is present at $APPLICATIONS/OneDrive.app but its version could not be read: both CFBundleVersion and CFBundleShortVersionString are missing or unreadable in $APPLICATIONS/OneDrive.app/Contents/Info.plist."
    log "ERROR: without the installed version, the downgrade guard cannot prove the vendored pkg (${vendored_version:-unknown}) is not a downgrade, so it fails closed."
    log "ERROR: remedy: fix or reinstall OneDrive so its Info.plist is readable, or remove $APPLICATIONS/OneDrive.app if the bundle is corrupt — then re-run ./s."
    log "ERROR: aborting before brew bundle so the failure is this message, not the installer's."
    exit 1
  fi
  if [ -n "$vendored_version" ] && [ -n "$installed_version" ] &&
    [ "$(vercmp "$installed_version" "$vendored_version")" = "1" ]; then
    log "ERROR: OneDrive self-updated to $installed_version — newer than the vendored cask ($vendored_version) — before brew adopted it."
    log "ERROR: the vendored pkg would be a downgrade and its installer would refuse it inside brew bundle."
    log "ERROR: remedy: bump homebrew-local/Casks/onedrive.rb to $installed_version (same URL pattern; sha256 of Microsoft's pkg for that version), or comment the onedrive entry in casks.nix back out — then re-run ./s."
    log "ERROR: aborting before brew bundle so the failure is this message, not the installer's."
    exit 1
  fi
  log "onedrive: installed version ${installed_version:-unknown}, vendored cask ${vendored_version:-unknown} — brew bundle will install the vendored pkg (same-or-newer) and take over management"
else
  log "onedrive: no app at $APPLICATIONS/OneDrive.app; brew bundle will install the vendored cask fresh"
fi

exit 0
