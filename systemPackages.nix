{
  inputs,
  system,
  pkgs,
  ...
}:
let
  ocPkgs = inputs.self.packages.${system};

  # Chromium-family with structural CDP (developing-today/code#5924
  # follow-up; fleet rule: every browser exposes the DevTools
  # endpoint on loopback at every launch). The browsers themselves
  # are Homebrew casks (casks.nix) whose bundles cannot be wrapped in
  # place declaratively, so chromiumFamilyCdp provides the wrapped
  # launch paths: "<Browser> CDP" apps (linked into /Applications/Nix
  # Apps by nix-darwin's applications activation) and `<browser>-cdp`
  # CLI wrappers. Each execs the cask's real binary with the fleet
  # flags -- --remote-debugging-address=127.0.0.1 (loopback ONLY; the
  # remote path is loopback + tailscale serve / CONNECT proxy) and
  # the browser's fleet port. Caller args follow and win.
  #
  # IMPORTANT Chrome/Edge 136+ caveat (measured on Chrome 157 here):
  # Chrome and Edge refuse `--remote-debugging-port` on their default
  # user-data-dir ("DevTools remote debugging requires a non-default
  # data directory. Specify this using --user-data-dir."); Helium 0.19
  # removed that restriction and listens on 19222 even on its default
  # profile. For Chrome/Edge's default profile, `browser-remote-debug.py`
  # (run by `home.activation.browserRemoteDebug` in homeUser.nix) sets
  # `devtools.remote_debugging.user-enabled = true` in `Local State`,
  # which turns on the approval-gated CDP server on 127.0.0.1:9222 for
  # every normal launch (Dock, Spotlight, `open -a`). To run an
  # unattended fixed-port Chrome/Edge CDP session on 19223/19228, pass
  # `--user-data-dir=<dir>` to `google-chrome-cdp` / `microsoft-edge-cdp`.
  #
  # Fleet port table, one place for every browser remote endpoint,
  # loopback-only:
  #   19222 Helium CDP          19225 Firefox BiDi
  #   19223 Brave/Chrome CDP    19226 Zen BiDi
  #   19224 Chromium CDP        19227 Zen Twilight BiDi
  #   19228 Microsoft Edge CDP  19229 Safari BiDi (safaridriver -p 19230 -b 19229)
  #   19231 Safari Technology Preview BiDi (safaridriver -p 19232 -b 19231)
  chromiumFamilyCdp = pkgs.stdenvNoCC.mkDerivation {
    pname = "chromium-family-cdp";
    version = "1.1";
    src = null;
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out/bin"

      make_cdp_app() {
        display="$1"; bin_name="$2"; target="$3"; port="$4"; ident="$5"
        app="$out/Applications/$display.app"
        mkdir -p "$app/Contents/MacOS"
        cat > "$app/Contents/MacOS/$display" <<LAUNCHER
      #!/bin/sh
      exec "$target" --remote-debugging-address=127.0.0.1 --remote-debugging-port=$port "\$@"
      LAUNCHER
        chmod +x "$app/Contents/MacOS/$display"
        cat > "$app/Contents/Info.plist" <<PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleExecutable</key>
        <string>$display</string>
        <key>CFBundleIdentifier</key>
        <string>local.drewrypope.$ident</string>
        <key>CFBundleName</key>
        <string>$display</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>1.1</string>
        <key>LSUIElement</key>
        <false/>
      </dict>
      </plist>
      PLIST
        cat > "$out/bin/$bin_name" <<LAUNCHER
      #!/bin/sh
      exec "$target" --remote-debugging-address=127.0.0.1 --remote-debugging-port=$port "\$@"
      LAUNCHER
        chmod +x "$out/bin/$bin_name"
      }

      make_cdp_app "Helium CDP" helium-cdp "/Applications/Helium.app/Contents/MacOS/Helium" 19222 helium-cdp
      make_cdp_app "Google Chrome CDP" google-chrome-cdp "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" 19223 google-chrome-cdp
      make_cdp_app "Microsoft Edge CDP" microsoft-edge-cdp "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" 19228 microsoft-edge-cdp
    '';
    meta = {
      description = "Helium, Google Chrome and Microsoft Edge launchers with CDP remote debugging on loopback (19222/19223/19228)";
      platforms = pkgs.lib.platforms.darwin;
    };
  };
  # Firefox-family with structural WebDriver BiDi (code#5924
  # follow-up): Firefox, Zen and Zen Twilight have no CDP --
  # --remote-debugging-port starts their WebDriver BiDi remote
  # agent instead (Firefox 160 / Zen 1.24t have no profile pref that
  # auto-starts RemoteAgent without this CLI flag). Same launcher-app
  # + CLI shape as chromiumFamilyCdp above: the cask bundles cannot
  # be wrapped in place, so each browser gets a "<Name> BiDi" app
  # (linked into /Applications/Nix Apps) and a `<name>-bidi` CLI,
  # both exec'ing the cask's real binary with the flag. Because
  # `exec` preserves argv[0]'s target binary path (`NSBundle.mainBundle`
  # resolves to `/Applications/{Firefox,Zen,Twilight}.app`), Mozilla's
  # CityHash64 `installs.ini` hash stays identical to launching the
  # stock app -- existing profiles (`df40mpog.Default (alpha)`, etc.)
  # are reused without creating a blank profile.
  #
  # Default-browser URL clicks (`http`/`https`/`public.html`) are
  # pinned in configuration.nix (`duti -s local.drewrypope.zen-twilight-bidi`)
  # so any cold-start from clicking a link starts Zen Twilight WITH
  # WebDriver BiDi on 127.0.0.1:19227 instead of bypassing the wrapper.
  #
  # The remote agent binds 127.0.0.1 itself; NO --remote-debugging-address
  # flag (that is a Chromium flag; the Firefox agent has no such option)
  # and no --remote-allow-origins: Firefox's default Host/Origin policy
  # stays intact, so web content cannot hijack the socket and local
  # tooling (no Origin) works as-is.
  firefoxFamilyBidi = pkgs.stdenvNoCC.mkDerivation {
    pname = "firefox-family-bidi";
    version = "1.1";
    src = null;
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out/bin"

      make_app() {
        display="$1"; bin_name="$2"; target="$3"; port="$4"; ident="$5"
        app="$out/Applications/$display.app"
        mkdir -p "$app/Contents/MacOS"
        cat > "$app/Contents/MacOS/$display" <<LAUNCHER
      #!/bin/sh
      exec "$target" --remote-debugging-port=$port "\$@"
      LAUNCHER
        chmod +x "$app/Contents/MacOS/$display"
        cat > "$app/Contents/Info.plist" <<PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleExecutable</key>
        <string>$display</string>
        <key>CFBundleIdentifier</key>
        <string>local.drewrypope.$ident</string>
        <key>CFBundleName</key>
        <string>$display</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>1.1</string>
        <key>CFBundleURLTypes</key>
        <array>
          <dict>
            <key>CFBundleURLName</key>
            <string>Web site URL</string>
            <key>CFBundleURLSchemes</key>
            <array>
              <string>http</string>
              <string>https</string>
            </array>
          </dict>
        </array>
        <key>CFBundleDocumentTypes</key>
        <array>
          <dict>
            <key>CFBundleTypeName</key>
            <string>HTML document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
              <string>public.html</string>
              <string>public.xhtml</string>
            </array>
          </dict>
        </array>
      </dict>
      </plist>
      PLIST
        cat > "$out/bin/$bin_name" <<LAUNCHER
      #!/bin/sh
      exec "$target" --remote-debugging-port=$port "\$@"
      LAUNCHER
        chmod +x "$out/bin/$bin_name"
      }

      make_app "Firefox BiDi" firefox-bidi "/Applications/Firefox.app/Contents/MacOS/firefox" 19225 firefox-bidi
      make_app "Zen BiDi" zen-bidi "/Applications/Zen.app/Contents/MacOS/zen" 19226 zen-bidi
      make_app "Zen Twilight BiDi" zen-twilight-bidi "/Applications/Twilight.app/Contents/MacOS/zen" 19227 zen-twilight-bidi
    '';
    meta = {
      description = "Firefox, Zen and Zen Twilight launchers with WebDriver BiDi remote debugging on loopback (19225/19226/19227)";
      platforms = pkgs.lib.platforms.darwin;
    };
  };
  # Safari & Safari Technology Preview WebDriver BiDi launcher CLIs.
  # macOS 26 ships native WebDriver BiDi (`safaridriver -b <port>`) and a
  # native stdio MCP server (`safaridriver --mcp`, wired in mcpx.config.nix).
  # `postActivation` in configuration.nix runs `safaridriver --enable` so
  # sessions require no interactive admin prompt once "Allow remote
  # automation" is enabled in Safari > Settings > Developer.
  safariFamilyBidi = pkgs.stdenvNoCC.mkDerivation {
    pname = "safari-family-bidi";
    version = "1.0";
    src = null;
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out/bin"

      cat > "$out/bin/safari-bidi" <<'LAUNCHER'
      #!/bin/sh
      exec /usr/bin/safaridriver -p 19230 -b 19229 "$@"
      LAUNCHER
      chmod +x "$out/bin/safari-bidi"

      cat > "$out/bin/safari-tp-bidi" <<'LAUNCHER'
      #!/bin/sh
      stp_driver="/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver"
      if [ ! -x "$stp_driver" ]; then
        echo "safari-tp-bidi: $stp_driver is not installed (run brew install --cask --force safari-technology-preview)" >&2
        exit 1
      fi
      exec "$stp_driver" -p 19232 -b 19231 "$@"
      LAUNCHER
      chmod +x "$out/bin/safari-tp-bidi"
    '';
    meta = {
      description = "Safari and Safari Technology Preview WebDriver BiDi server launchers on loopback (19229/19231)";
      platforms = pkgs.lib.platforms.darwin;
    };
  };

in
{
  environment.systemPackages =
    with pkgs;
    [
      colima
      cargo-cache # `cargo cache -r all` in ./clean; ~/.cargo has no built-in pruner
      chromiumFamilyCdp # Helium/Chrome/Edge launchers with structural CDP on 127.0.0.1:19222/19223/19228 (code#5924)
      firefoxFamilyBidi # Firefox/Zen/Zen Twilight launchers with structural WebDriver BiDi on 127.0.0.1:19225/19226/19227 (code#5924)
      safariFamilyBidi # Safari / Safari Technology Preview WebDriver BiDi launchers on 127.0.0.1:19229/19231

      duti # sets LaunchServices URL/UTI handlers; used to pin the default browser
      doggo
      docker-client
      uv
      ruff
      docker-compose
      inputs.nixpkgs-terraform.packages.${system}."terraform-1.5.7"
      # possibly not darwin
      powershell
      oils-for-unix
      # zen-browser
      _1password-cli
      act
      # github-copilot-cli # Gen-1 npm CLI deprecated; replaced by native `copilot-cli` cask
      # copilot-cli
      age
      # dbeaver-bin # removed 2026-09-15: reclaiming disk (use DBeaver.app)
      yq-go
      # nixd # 2025-10-15 fixed in staging
      age-plugin-yubikey
      alacritty
      # ansible # DISABLED 2026-08: ~2.1 GB closure, ~640 MB of it dependencies
      # almost nothing else uses. Re-enable if you need it.
      # arduino-cli # removed 2026-09-15: reclaiming disk (embedded; platformio also removed)
      # terraform
      powershell
      aspell
      aspellDicts.en
      nixfmt
      # awscli # removed 2026-09-15: reclaiming disk; use AWS SDK / CloudShell
      azure-cli
      # Anthropic's Claude Code CLI (unfree; allowed by nixpkgs.config.allowUnfree).
      claude-code
      direnv
      nix-direnv
      jujutsu
      lazyjj
      bandwhich
      bash-completion
      bat
      # Bitwarden: desktop app, personal vault CLI (`bw`), and Secrets Manager CLI (`bws`).
      bitwarden-desktop
      bitwarden-cli
      bws
      # whalebrew?
      # kitty # removed 2026-09-15: reclaiming disk
      zellij
      tmux
      jankyborders
      sketchybar
      # sketchybar-app-font
      screen
      black
      btop
      # (buf.overrideAttrs { doCheck = false; }) # removed 2026-09-15: reclaiming disk (WASM plugin timeout in TestRunBreakingPolicyLocal under Nix sandbox)
      stow
      caddy
      certstrap
      # cfssl # removed 2026-09-15: reclaiming disk
      # chromium # driverLink not supported on darwin - 2026-03-29
      # helium
      cocoapods
      coreutils
      curl
      dbmate
      # dejavu_fonts
      deno
      # devenv
      difftastic
      # dive # removed 2026-09-15: reclaiming disk
      dust
      # emacs
      # emacs-unstable
      # emacs-all-the-icons-fonts
      # fastlane # removed 2026-09-15: reclaiming disk (iOS/Android release automation)
      fd
      ffmpeg
      # flyctl # removed 2026-09-15: reclaiming disk
      # font-awesome
      fzf
      gcc
      gh
      git
      git-filter-repo
      git-lfs
      glow
      gnupg
      gnused
      gnumake
      go
      # golangci # ???
      # gomplate # removed 2026-09-15: reclaiming disk
      # google-cloud-sdk # removed 2026-09-15: reclaiming disk
      gopls
      # goreleaser # removed 2026-09-15: reclaiming disk
      graphviz
      gum
      # hack-font
      # hcloud # removed 2026-09-15: reclaiming disk
      htop
      httpie
      # hugo # removed 2026-09-15: reclaiming disk
      hunspell
      iftop
      imagemagick
      inetutils
      ipcalc
      # jdk17
      jetbrains-mono
      # jetbrains.phpstorm
      jpegoptim
      jq
      jwt-cli
      # k3d # removed 2026-09-15: reclaiming disk
      # k9s # removed 2026-09-15: reclaiming disk (helm-unittest/k3d cover local testing)
      # killall # removed 2026-09-15: reclaiming disk (macOS /usr/bin/killall remains)
      # argo-workflows # removed 2026-09-15: reclaiming disk (Argo Workflows engine, NOT Argo CD)
      kubernetes-helm
      kubernetes-helmPlugins.helm-unittest
      kubectl
      libfido2
      lima
      lnav
      mas
      meslo-lgs-nf
      micro
      # mitmproxy # broken on master 2026-02-26
      # mutagen # removed 2026-09-15: reclaiming disk
      # mutagen-compose # removed 2026-09-15: reclaiming disk
      # nats-server # removed 2026-09-15: reclaiming disk
      # natscli # removed 2026-09-15: reclaiming disk
      #ncdu
      # fastfetch # removed 2026-09-15: reclaiming disk (also disabled programs.fastfetch below)
      neovim
      # ngrok # removed 2026-09-15: reclaiming disk
      nmap
      bun
      nodejs
      pnpm
      # noto-fonts
      # noto-fonts-emoji
      #openfortivpn
      # OpenCode from developing-today-forks/opencode, wrapped to pin the database
      # and scratch dir (flake.nix mkPackages). The only opencode on PATH.
      ocPkgs.opencode
      # OpenChamber's server CLI. The server itself runs as the openchamber
      # launchd agent and the desktop app is installed by openchamber.nix.
      ocPkgs.openchamber
      # The MCP gateway (the opencode fork's mcpx build, re-exposed as
      # this flake's packages.mcpx in flake.nix; origin:
      # developing-today/code's pkgs/mcpx). Its daemon runs at login from the
      # mcpx launchd agent in configuration.nix; the CLI reaches it from any shell.
      inputs.self.packages.${system}.mcpx
      # The servers in mcpx.config.nix run from these, by absolute
      # /run/current-system/sw/bin path.
      terraform-mcp-server
      playwright-mcp
      mcp-server-sequential-thinking
      markitdown-mcp
      mcp-nixos
      # mcp-remote and chrome-devtools-mcp, which are only on npm (pinned by
      # pkgs/npm-mcp-servers/package-lock.json).
      inputs.self.packages.${system}.npm-mcp-servers
      # service-event, for scripts that record into the service event log
      # (configuration.nix launchd.user.agents.service-events).
      inputs.self.packages.${system}.service-events
      # AWS credentials for the `aws` MCP server (mcp-proxy-for-aws signs with
      # the default profile): `aws configure sso`, then `aws sso login`.
      awscli2
      # Atlassian's Teamwork Graph CLI (twg) — prebuilt binary, pinned in
      # pkgs/twg-cli/hashes.json. Not an MCP server itself (the Atlassian MCP
      # server is already configured as "atlassian" in mcpx.config.nix);
      # twg is a standalone CLI an agent
      # shells out to. First run needs `twg setup` (OAuth login) and
      # `twg doctor` interactively — not something Nix can do at build time.
      inputs.self.packages.${system}.twg-cli
      # GitHub's official MCP server, run with the token `gh` already holds in
      # the login keychain, so no token is stored here or in the nix store.
      # Its hosted server (api.githubcopilot.com/mcp) cannot do mcp-remote's
      # OAuth -- no dynamic client registration -- which is why it runs locally.
      # mcpx.config.nix starts it by this name's absolute path, since the
      # launchd agents' PATH does not include the system profile.
      (pkgs.writeShellApplication {
        name = "github-mcp";
        runtimeInputs = [
          pkgs.gh
          pkgs.github-mcp-server
        ];
        text = ''
          GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token)"
          export GITHUB_PERSONAL_ACCESS_TOKEN
          exec github-mcp-server stdio "$@"
        '';
      })
      # Plannotator's only distribution channel is its upstream install
      # script; #1433 took the activation-time curl-pipe-to-bash out of
      # homeUser.nix. This explicit setup/update command is the
      # deliberate, user-invoked replacement: nothing runs at switch
      # time, and installer failures surface (writeShellApplication
      # runs with errexit/nounset/pipefail and no output suppression).
      (pkgs.writeShellApplication {
        name = "plannotator-setup";
        runtimeInputs = [
          pkgs.curl
          pkgs.bash
        ];
        text = ''
          echo "plannotator-setup: installing/updating Plannotator via https://plannotator.ai/install.sh ..." >&2
          curl -fsSL https://plannotator.ai/install.sh | bash
          echo "plannotator-setup: installer finished" >&2
        '';
      })
      inputs.self.packages.${system}.opencode-share
      inputs.self.packages.${system}.sidepulse
      inputs.self.packages.${system}.sidepulse-setup
      # openjdk # removed 2026-09-15: reclaiming disk (Azul Zulu JDK)
      # Oracle Cloud Infrastructure CLI; provides the `oci` command.
      oci-cli
      openssh
      p7zip
      # pandoc # removed 2026-09-15: reclaiming disk
      pgcli
      # php81
      # platformio # removed 2026-09-15: reclaiming disk
      playwright-driver.browsers
      # The pinned Playwright CLI (#1433: replaces the activation-time
      # global npm install in homeUser.nix). The version
      # is fixed by nixpkgs, and its browsers are
      # playwright-driver.browsers above.
      playwright-test
      pngquant
      protobuf
      protoc-gen-go
      protoc-gen-go-grpc
      python3
      bash
      # python39
      # python39Packages.virtualenv
      # redis # removed 2026-09-15: reclaiming disk
      ripgrep
      treefmt
      shfmt
      yamlfmt
      taplo
      prettier
      shellcheck
      # hadolint # removed 2026-09-15: reclaiming disk (Dockerfile linter)
      dockerfmt
      # slack
      sops
      sqlite
      ssh-to-age
      ssm-session-manager-plugin
      # symfony-cli # removed 2026-09-15: reclaiming disk (PHP tooling; php already commented)
      tflint
      tmux
      tree
      # trivy # removed 2026-09-15: reclaiming disk
      unrar
      unzip
      upx
      # vector
      vim
      # watchman
      wget
      yarn
      zip
      zstd
      # zsh-powerlevel10k — replaced by programs.starship (cross-shell, Rust, faster)
      # Rust toolchain via fenix (replaces bare cargo) — stable with all dev components
      # Rust toolchain removed 2026-09-15: reclaiming disk (~880 MB). Re-enable if you need cargo/rustc/rust-analyzer.
      # (pkgs.fenix.stable.withComponents [
      #   "cargo"
      #   "clippy"
      #   "rustc"
      #   "rustfmt"
      #   "rust-src" # needed by rust-analyzer for goto-definition into std
      #   "rust-analyzer" # LSP server
      #   "llvm-tools" # code coverage, llvm-profdata, llvm-cov
      # ])
      # Nightly-only: miri (undefined behavior detector) — use fenix.complete for nightly components
      # pkgs.fenix.complete.miri
      # Extra cargo tools removed 2026-09-15: orphaned after Rust toolchain removal (need cargo/rustc to function)
      # cargo-watch # auto-rebuild on file changes
      # cargo-expand # macro expansion viewer
      # cargo-edit # `cargo add`, `cargo rm`, `cargo upgrade`
      # cargo-nextest # faster test runner
      # cargo-udeps # find unused dependencies
      # cargo-deny # lint deps for licenses, bans, advisories
      # cargo-flamegraph # profiling flamegraphs
      # cargo-audit # security vulnerability scanner
      # cargo-insta # snapshot testing
      # zig # removed 2026-09-15: reclaiming disk
      # swiftPackages.swift # removed 2026-09-15: reclaiming disk (~880 MB; drops swiftc, nothing else depends on it)
      # dotnet-sdk_9 # DISABLED 2026-08: ~1.2 GB closure, ~590 MB of near-private
      # dependencies. Re-enable if you need .NET.
      inputs.just.packages.${system}.default
      # linker/binary diagnostic and fixing tools
      patchelf # fix ELF binaries (rpath, interpreter) - essential for Linux containers/cross-compile
      binutils # readelf, objdump, nm, strings - inspect binaries
      file # identify binary types (ELF vs Mach-O, architecture)
      darwin.trash # `trash` command — moves files to macOS Trash instead of permanent deletion
      inputs.self.packages.${system}.brew-repair
      inputs.self.packages.${system}.codedb
      pkgs.codebase-memory-mcp
      pkgs.fff-mcp
    ]
    ++ [
      # darwin
      cctools # install_name_tool, otool, lipo - inspect/fix Mach-O binaries
      aerospace
      dockutil
      fswatch
      noTunes
      # rectangle
    ];
}
