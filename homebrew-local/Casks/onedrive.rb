# Vendored copy of homebrew-cask's `onedrive`, pinned to the OneDrive
# build installed on this machine (#1791). Upstream's cask tracks
# Microsoft's Deferred ring (its livecheck follows fwlink 823060) and
# sat at 26.189.0928.0009 while the machine's OneDrive — installed
# outside brew and self-updating on the Production ring — was already
# at 26.198.1011.0006. With no brew receipt, every activation's
# `brew bundle` ran the upstream pkg and the installer refused the
# downgrade, failing the switch. Installing THIS cask is a same-version
# install, which the installer allows, and it writes brew's Caskroom
# receipt: brew owns OneDrive from then on while the app keeps
# self-updating (auto_updates).
#
# sha256 is of Microsoft's own pkg at the URL below for this version
# (289,917,016 bytes, verified 2026-11-11). The upstream livecheck
# block is deliberately omitted: it reports the Deferred ring, the
# wrong signal for this pin.
#
# RETIRE this file (and the dezren39/homebrew-local tap + trust entry
# in configuration.nix, and switch casks.nix back to plain "onedrive")
# once the pinned upstream homebrew-cask reaches >= 26.198.1011.0006.
# brew-adopt-unmanaged.sh logs that moment at activation.
cask "onedrive" do
  version "26.198.1011.0006"
  sha256 "928516faca5cc0ccecdf939b9e101eddf252aea76d499d9ffe2c29b421818bf2"

  url "https://oneclient.sfx.ms/Mac/Installers/#{version}/universal/OneDrive.pkg"
  name "OneDrive"
  desc "Cloud storage client"
  homepage "https://www.microsoft.com/en-us/microsoft-365/onedrive/online-cloud-storage"

  auto_updates true
  conflicts_with cask: [
    "microsoft-office",
    "microsoft-office-businesspro",
  ]
  depends_on macos: :sonoma

  pkg "OneDrive.pkg"

  uninstall launchctl: [
              "com.microsoft.OneDriveStandaloneUpdater",
              "com.microsoft.OneDriveStandaloneUpdaterDaemon",
              "com.microsoft.OneDriveUpdaterDaemon",
              "com.microsoft.SyncReporter",
            ],
            quit:      [
              "com.microsoft.OneDrive",
              "com.microsoft.OneDrive.FinderSync",
              "com.microsoft.OneDriveUpdater",
            ],
            pkgutil:   "com.microsoft.OneDrive",
            delete:    [
              "/Applications/OneDrive.app",
              "/Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist",
              "/Library/LaunchDaemons/com.microsoft.OneDriveStandaloneUpdaterDaemon.plist",
              "/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist",
              "/Library/Logs/Microsoft/OneDrive",
            ]

  zap trash: [
    "~/Library/Application Scripts/*.OfficeOneDriveSyncIntegration",
    "~/Library/Application Scripts/*.OneDriveStandaloneSuite",
    "~/Library/Application Scripts/com.microsoft.OneDrive-mac",
    "~/Library/Application Scripts/com.microsoft.OneDrive.FileProvider",
    "~/Library/Application Scripts/com.microsoft.OneDrive.FinderSync",
    "~/Library/Application Scripts/com.microsoft.OneDriveLauncher",
    "~/Library/Application Support/com.microsoft.OneDrive",
    "~/Library/Application Support/com.microsoft.OneDriveUpdater",
    "~/Library/Application Support/FileProvider/com.microsoft.OneDrive.FileProvider",
    "~/Library/Application Support/OneDrive",
    "~/Library/Application Support/OneDriveUpdater",
    "~/Library/Caches/com.microsoft.OneDrive",
    "~/Library/Caches/com.microsoft.OneDriveStandaloneUpdater",
    "~/Library/Caches/com.microsoft.OneDriveUpdater",
    "~/Library/Caches/com.plausiblelabs.crashreporter.data/com.microsoft.OneDrive",
    "~/Library/Caches/com.plausiblelabs.crashreporter.data/com.microsoft.OneDriveUpdater",
    "~/Library/Caches/OneDrive",
    "~/Library/Containers/com.microsoft.OneDrive.FileProvider",
    "~/Library/Containers/com.microsoft.OneDrive.FinderSync",
    "~/Library/Containers/com.microsoft.OneDriveLauncher",
    "~/Library/Cookies/com.microsoft.OneDrive.binarycookies",
    "~/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies",
    "~/Library/Group Containers/*.OfficeOneDriveSyncIntegration",
    "~/Library/Group Containers/*.OneDriveStandaloneSuite",
    "~/Library/Group Containers/*.OneDriveSyncClientSuite",
    "~/Library/HTTPStorages/com.microsoft.OneDrive",
    "~/Library/HTTPStorages/com.microsoft.OneDrive.binarycookies",
    "~/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater",
    "~/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater.binarycookies",
    "~/Library/Logs/OneDrive",
    "~/Library/Preferences/*.OneDriveStandaloneSuite.plist",
    "~/Library/Preferences/com.microsoft.OneDrive.plist",
    "~/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist",
    "~/Library/Preferences/com.microsoft.OneDriveUpdater.plist",
    "~/Library/WebKit/com.microsoft.OneDrive",
  ]
end
