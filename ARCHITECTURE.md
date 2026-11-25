# nix config — architecture & features

Single-user **nix-darwin + home-manager + nix-homebrew** flake for an Apple
Silicon (`aarch64-darwin`) Mac, plus a substantial local AI-tooling
(OpenCode / OpenChamber / Copilot / mcpx) setup. This document catches a human or agent up
on the whole repo.

SPDX-License-Identifier: MIT OR Apache-2.0

---

## 1. Top-level layout

```
flake.nix              Flake entry: inputs, darwinConfigurations, packages, apps, devShell, checks
configuration.nix      Main nix-darwin module (system defaults, homebrew, launchd, activation)
homeUser.nix           home-manager per-user module (imports homePackages + homePrograms)
homePackages.nix       home-manager packages (stub: just `hello`)
homePrograms.nix       home-manager programs (shells, git, ghostty, atuin, starship, setup-opencode)
systemPackages.nix     environment.systemPackages (~180 pkgs — the real package list)
nix.settings.nix       nix daemon settings (experimental-features, substituters)
services.nix           nix-darwin services (aerospace, skhd, jankyborders)
brews.nix casks.nix masApps.nix   homebrew formulae / casks / mas apps
treefmt.nix            formatter config (nixfmt + rustfmt) — used by flake `formatter`/`checks`

pkgs/                  Custom packages (see §4)
patches/               sidepulse patch stack (OpenCode is not patched; see §5)
*.patch (root)         homebrew-services fix (unused)
openchamber.nix        OpenChamber server launchd agent + desktop client (§5)
mcpx-agent.nix         Runs the mcpx agent on ~/.config/mcpx/config.json, the path every client names
docs/                  services.md (how OpenChamber, OpenCode and mcpx run, are replaced
                       on a switch, checked and debugged), mcp.md (every MCP server, its
                       auth and credentials), dated reviews, sidepulse docs
                       (canonical copies of services.md, mcp.md and the dated reviews:
                       developing-today/code doc/fleet/)
instructions/          OpenCode instruction files (worktrees, recordings, work-strategies; archive/)
                       (canonical copies: developing-today/code doc/platform/)
commands/              OpenCode slash commands (/gha-fix, /gha-why, /tokenscope, /warp-import)
.agents/skills/        Repo-local agent skills (see §7)
opencode-global.jsonc  OpenCode v2 global config: a mirror of the live ~/.opencode/opencode.jsonc, not linked to it (see §5)
tui.jsonc              v1 TUI config; v2 ignores it (v2 reads ~/.config/opencode/cli.json)
sounds/                Star Trek notification sounds (opencode-notifier)
themes/                Active TUI theme (vibrant-ink.json)
justfile               Task runner (rebuild, tidy, share, link-git, mcp logins)
rebuild.sh r / simple-rebuild.sh s / clean(.sh) / path.sh   Rebuild + cleanup scripts
symlinker.sh           Large bash symlink manager (source for pkgs/symlinker)
.aerospace.toml        AeroSpace tiling WM config
mcpx.config.nix        Every MCP server, and how mcpx pools it
config.toml            One of three copies of the VSCode extension list (with code-install-extensions.sh's hardcoded lines and vsc-extensions.txt); the installer never reads it — the copies are kept identical by the drift check in code-install-extensions-tests (#1547)
.github/workflows/     opencode.yml (/oc comment bot), mcpx-nixbuild.yml (mcpx package build)
```

### Wiring (module composition)

The two entry modules compose sub-files with `lib.recursiveUpdate` (deep merge),
**not** the standard `imports` list:

```
flake.nix → ./configuration.nix
  ├─ imports: systemPackages, brews, casks, masApps, services
  ├─ recursiveUpdate with nix.settings.nix
  └─ home-manager.users."drewry.pope" = ./homeUser.nix
        ├─ recursiveUpdate homePackages.nix
        └─ recursiveUpdate homePrograms.nix
```

---

## 2. The flake (`flake.nix`)

- **Target:** `aarch64-darwin`, single default host keyed by `scutil --get
LocalHostName` (`hosts = { MGM9JJ4V3R = { ... }; }`). `darwinSystemConfigurations`
  merges `defaultDarwinSystem` with per-host overrides.
- **Stack inputs:** determinate (Determinate Nix), nix-darwin, home-manager,
  mac-app-util, nix-homebrew (+ brew-src, homebrew-core/cask/bundle/services and
  third-party taps), NUR, fenix (Rust), treefmt-nix, just, nixpkgs-terraform,
  `openchamber` (github:developing-today-forks/openchamber, our fork), whose own
  `opencode` input pins developing-today-forks/opencode. There is no root
  `opencode` input; its code and mcpx source arrive through that chain.
- **Input hygiene:** a heavy `follows` graph plus `nixpkgs-hoisted*` inputs keeps
  transitive nixpkgs deduplicated. This is maintained by the custom **flake-tidy**
  tool (§4).
- **`mkPackages`** (single source of package defs, reused by `packages`, `apps`,
  `devShells`, `checks`): builds `bun-bin`; `mcpx` (the fork's build,
  re-exposed from the openchamber -> opencode chain - not built here,
  #1388); `opencode-unwrapped` (the fork's package, unmodified - it
  already bundles the fork's mcpx) and `opencode` (a wrapper pinning
  `OPENCODE_DB` and `TMPDIR`); `openchamber` (the fork's server built against
  that `opencode`); plus `brew-repair`, `codedb`, `flake-tidy`, `twg-cli`,
  `npm-mcp-servers`, `opencode-share`, `symlinker`.
- **checks:** `formatting` (treefmt), `tidy` (flake-tidy `--check`),
  `flake-tidy-tests` (the flake-tidy pytest suite), `plugins-tests`
  (plugins/*.test.mjs), `opencode-db-pids-tests` on every supported system; the Sidepulse
  package build/test and setup smoke test run on Darwin only.
- **apps:** `flake-tidy`, `mcpx`, `opencode`, `openchamber`, `opencode-share`,
  `symlinker`, `adopt`; Sidepulse apps are Darwin-only.
- **devShell:** opencode, flake-tidy, symlinker, just, nixfmt, git, gh (with a
  version-printing shellHook); Sidepulse tools are added on Darwin only.

---

## 3. System configuration highlights

**`configuration.nix`**

- System-wide git ignore/config written to `/etc/gitignore` + `/etc/gitconfig`,
  forced onto Nix's git via `GIT_CONFIG_SYSTEM` (blocks `codedb.snapshot`).
- `nixpkgs`: `allowUnfree/allowBroken/allowUnsupportedSystem`; overlays add fenix
  and the custom `noTunes` app.
- `system.defaults`: fast key repeat, disabled press-and-hold, silenced beep,
  auto-hide menu bar, trackpad tap-to-click, and a curated Spotlight preference
  block.
- **nix-homebrew:** Rosetta on, `mutableTaps=false`, declarative `trust.formulae`,
  custom taps (firefox-profile-switcher, autoraise, fuse).
- **`nix.enable = false`** — Determinate Nix owns the daemon; package forced to
  `nixVersions.git`.
- **activationScripts:** menu-bar spacing, disable font smoothing, kickstart skhd,
  exclude `/nix` from Spotlight, xcode-select + license accept.
- **launchd agents:** `naturalScrollingToggle` (flip scroll dir by mouse presence),
  `colima`, and `mcpx` (the MCP gateway daemon; servers in `mcpx.config.nix`).
  OpenChamber's agent is in `openchamber.nix`.

**`nix.settings.nix`** — broad `experimental-features` (flakes, ca-derivations,
dynamic-derivations, recursive-nix, pipe-operators, …); extra substituters for
nixpkgs-terraform + fenix; perf tuning (`http-connections=100`,
`max-substitution-jobs=64`, `keep-outputs/derivations`).

**`systemPackages.nix`** — containers (colima/docker/lima/k3d/k9s/kubectl),
cloud/IaC (pinned `terraform-1.5.7`, awscli, gcloud, sops+age), languages
(go/node/bun/python/dotnet_9/zig/swift + fenix Rust toolchain + many `cargo-*`),
plus the repo's own flake packages. `buf` is overridden with `doCheck=false`.

**`services.nix`** — `aerospace` (config from `.aerospace.toml` via
`fromTOML`), `skhd` (remaps `cmd-q`, binds toggle-menubar), `jankyborders`.
(yabai/sketchybar present but commented.)

**`homeUser.nix`** — after `writeBoundary`, activation runs the packaged
`sidepulse setup` for the `sidepulseProviders` list (OpenCode by default). Edit
that list to change which providers are managed.

**`homePrograms.nix`** — bash/zsh/fish sharing aliases + init (`rm=trash`, cargo
linker pinned to `/usr/bin/cc`, credential helpers, an aerospace+fzf window
switcher, and a `setup-opencode()` helper that symlinks a central `.opencode`
into projects). Also atuin (Ctrl-R history), starship, direnv+nix-direnv, git
(work identity, `safe.directory=*`), ghostty (ghostty-bin, synthwave theme).

---

## 4. Custom packages (`pkgs/`)

| Package               | Lang                                                   | Wrapper                          | What it does                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------------------- | ------------------------------------------------------ | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **flake-tidy** ⭐     | Python 3 (~3300 lines)                                 | `writeShellApplication`          | Deduplicates/merges/flattens flake inputs by adding `follows`; edits `flake.nix`, reruns `nix flake lock` with backout, reformats. `dedup`/`merge`/`flatten`/`all` subcommands, `--check`/`--dry-run`. **~144 pytest tests** + fixtures.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| bun-bin               | Nix                                                    | `mkDerivation`                   | Prebuilt Bun (currently 1.4.4); Darwin re-signs via `install_name_tool`+`rcodesign`. Hashes in `hashes.json`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| mcpx                  | Go                                                     | `buildGo127Module` (upstream)    | MCP gateway / Code Mode runner. Source is developing-today/code's `pkgs/mcpx` (the only copy); the package is not built here - it arrives through the openchamber -> opencode chain (#1388) and flake.nix only re-exposes it. Its daemon runs as a launchd agent. Darwin skips the Linux-only takeover tests (the -skip list is constructed in code's package, not in flake.nix).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| brew-repair           | Bash (+py)                                             | `writeShellScriptBin`            | Detects casks brew thinks are installed but whose `.app` is missing; selectively reinstalls. `--dry-run/--quiet/--skip`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| adopt                 | Bash                                                   | `writeShellScriptBin`            | `nix run .#adopt [TEMPLATE]`: adds the current Mac (its LocalHostName) to flake.nix's `hosts` map — default entry, a copy of an existing host, or a template file — so its darwinConfiguration exists; then `./s`. Idempotent.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| opencode-share        | Bash                                                   | `writeShellApplication`          | Shares one `.opencode` across projects via nested **bindfs** mounts while keeping per-project `plans/`. mount/unmount/status/dry-run.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| symlinker             | Bash (~1250 lines, source at repo root `symlinker.sh`) | `writeShellApplication`          | Bulk symlink manager with backup, undo (v2 RELINK), filters, dry-run.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| buffer-backup         | TypeScript (own flake)                                 | own flake                        | VS Code extension: auto-backs-up unsaved buffers with SHA-256 dedup + retention.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| noTunes.nix           | Nix                                                    | `mkDerivation`                   | macOS app that stops Apple Music auto-launch.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| codedb                | Zig binary                                             | `fetchurl`                       | Pinned signed/notarized AST-aware code search and MCP server.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| fff-mcp               | Rust binary                                            | `fetchurl`                       | Pinned frecency-ranked file/content search MCP server.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| npm-mcp-servers       | Node/Nix                                               | `importNpmLock.buildNodeModules` | `mcp-remote` and `chrome-devtools-mcp`, which are only published to npm, pinned by a committed `package-lock.json`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| azure-mcp             | .NET single-file binary                                | `fetchurl`                       | Darwin-only. Microsoft's Azure MCP Server (`azmcp`), the self-contained build npm publishes as `@azure/mcp-<os>-<arch>`, pinned in `hashes.json`. No .NET SDK or runtime is installed. mcpx runs it as the `azure` namespace.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| kubernetes-mcp-server | Go binary                                              | `fetchurl`                       | Darwin-only. containers/kubernetes-mcp-server (not in nixpkgs), from its npm per-platform release, plus the read-only `config.toml` mcpx starts it with (the `kubernetes` namespace).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| record                | Node script                                            | `writeShellApplication`          | `record '<json-or-text>'` appends a line to `~/git/ai_recordings.jsonl` (`instructions/recordings.md`). Runs developing-today/code's `bin/record.mjs` from the code tree the opencode fork pins for mcpx; only the two files it needs are copied.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| sidepulse             | Python/PyObjC                                          | `buildPythonApplication`         | Darwin-only SidePulse CLI/status-bar app. Individually documented, an ordered stack of twelve patch files applies upstream PRs #14, #17, #26, #28, #29, #30, #31 and #32. PRs #33, #34 and #35 are local-only: #33 holds the LED completion signal until the user is visibly back at a terminal (`src/sidepulse/presence.py`) instead of timing out after 4s; #34 stops failures and permission prompts expiring on a clock (they persist while the owning process is alive, and are released when the session is deleted or its terminal is closed), keeps a failure from being overwritten by the idle that follows it, and widens OpenCode error capture to `message.updated` and the `session.next.*` runner; #35 adds multi-signal composition (`src/sidepulse/compose.py`): ten display modes over a ranked signal registry with demand/ambient tiers, eight static (`priority`, `round-robin`, `split`, `paired`, `orbit`, `depth`, `beacon`, `tide`) and two host-driven (`drift`, `live`), plus per-signal arrival announcements, a `tempo` pace dial and per-LED colour correction for the Dot's opposed LEDs. Selected by `multi_signal.mode`, defaulting to `beacon`. dezren39/darwin-nix#378 (`sidepulse-dezren39-nix-378-opencode-v2-plugin.patch`, last in the stack) makes `opencode_plugin_source()` generate the OpenCode v2 plugin (`export default { id, setup(ctx) }`, v2 run-lifecycle events mapped to the v1 names SidePulse already handles), so `sidepulse setup opencode` writes a plugin the v2 loader accepts. See `docs/sidepulse-modes.md` for every display mode, `docs/sidepulse-customisations.md` for what each local patch adds and the live LED configuration, and `docs/sidepulse-leds.md` for the verified hardware limits they work within. |
| sidepulse-setup       | Bash/Nix                                               | `writeShellApplication`          | Darwin-only wrapper providing `sidepulse --setup opencode` and `sidepulse setup opencode`; setup defaults to all upstream-supported providers. Home Manager invokes the packaged `sidepulse setup <provider>` for the configured provider list on every switch.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |

---

## 5. OpenCode integration

- **`opencode-global.jsonc`** — v2-native config that mirrors the live one.
  The live config is the plain file `~/.opencode/opencode.jsonc` (reached as
  `~/.config/opencode/opencode.jsonc`), which OpenChamber edits and which
  still uses some v1 key names; `just opencode-config-link` would replace it
  with a link to this file, and has not been run (checked 2026-11-24). Named so
  OpenCode's project walk (which loads `opencode.json`/`opencode.jsonc` from
  every directory up to the root) does not load it a second time as a project
  config for sessions inside this repo. `github-copilot` only. The routing is
  copied from the live file, comments included:
  - the default model is `github-copilot/claude-opus-5.5`; `build` is the
    default agent, `plan` is disabled, and no agent pins a model, so a subagent
    runs its parent's model unless its launch names one;
  - `experimental.model_routes` has one route per Copilot model (`luna`,
    `terra`, `sol`, `haiku`, `sonnet`, `opus`, `carbon`, `mai`; Gemini 4
    Hydrogen is commented out), hidden from the picker but callable as
    `opencode-route/<name>#<effort>`, and seven pools built from them, weakest
    and fastest first: `small`, `speed`, `scout`, `workhorse`, `specialist`,
    `summit`, plus `background` for long work nobody is waiting on;
  - every pool is `ordered` (the next leg only on failover) and pins each
    leg's effort, so a pool is called with no effort of its own; each leg
    carries its Artificial Analysis Intelligence Index score and minutes per
    task (index v5.1, 2026-11-16);
  - `subagent_depth` is 10 and `model_route_tuning` is on.

  `node .agents/skills/delegate/scripts/pools.mjs` prints the live pools;
  `--diff opencode-global.jsonc` exits 1 when this mirror has drifted from the
  live file. Instructions: `instructions/{worktrees,recordings,work-strategies}.md`.
  Plugins: opencode-notifier only (the v1 plugins fail v2's loader; listed in
  the file for when they are ported). `compaction.buffer = 8192`.

- **`tui.jsonc`** — v1 TUI config; v2 does not read it (`~/.config/opencode/cli.json`
  instead). Kept only until it is clear nothing else reads it.
- **`instructions/`** — `worktrees.md` (never create worktrees under /var),
  `recordings.md` (append notable moments with `record`), `work-strategies.md`
  (how to work here, including delegation and MCP scripting);
  `archive/subagents.md` is no longer loaded.
- **`commands/`** — `/gha-fix` (diagnose+fix a failed GitHub Actions job, with
  production-safety gating), `/gha-why` (analyze a _successful_ job),
  `/tokenscope` and `/warp-import`. `./symlink-commands` installs missing
  global command symlinks safely.
- **`mcpx.config.nix`** — every MCP server and its mcpx pooling, written to
  `~/.config/mcpx/config.json` by `homeUser.nix`. `azure` and `kubernetes` are
  read-only by the servers' own settings; `readOnlyTools` declares the
  unannotated read-only tools (nixos, deepwiki, markitdown) that the default
  `policy.write=ask` would otherwise hold for 45 s and refuse in a script.
  The daemon's PATH (`services.mcpx.environment.PATH` in `configuration.nix`)
  ends with the directories a login shell searches, so scripts it runs find
  `gh`, `az`, `kubectl` and `nix`; `just mcpx-exec-env` shows what they see.

### OpenCode and OpenChamber: our forks, no local patches

OpenCode and OpenChamber are built from forks we own
(developing-today-forks/opencode and developing-today-forks/openchamber, both `main`). Fixes
go into the fork, then the pins move up: opencode fork -> openchamber's lock ->
this repo's lock. `.agents/skills/update-opencode` is the procedure. The old
local patch stack was retired (TUI-only changes do not reach OpenChamber, the
rest is covered by v2); remaining server-side gaps are developing-today-forks/opencode#13
and developing-today-forks/openchamber#28.

- **One database.** `~/.local/share/opencode/opencode.db` holds every session.
  The `opencode` wrapper forces `OPENCODE_DB` to it, and `OPENCODE_DB` is also
  set in `environment.variables`, `launchd.user.envVariables` and home-manager
  `sessionVariables` (OpenChamber's server reads it directly). `just
opencode-db-backup` (APFS clone), `opencode-db-check`, `opencode-db-pending`.
- **Standing server** (`openchamber.nix`, ported from developing-today/code's
  systemd units): launchd agent `org.nixos.openchamber` runs `openchamber serve
--foreground` on 127.0.0.1:3000, managing one `opencode serve` reached through
  `~/.local/state/openchamber/bin/opencode`. A switch restarts the agent only
  when OpenChamber changed; a new OpenCode re-points the link and SIGHUPs for an
  in-place handover. The desktop app is a client of that server
  (`OPENCHAMBER_SERVER_URL`, `OPENCHAMBER_SKIP_LOCAL_SERVER`). Logs:
  `~/Library/Logs/openchamber.log`.

### Other patch files

- **homebrew-services.patch** — fixes a Homebrew `require_relative` path; wired via
  a **commented-out** `applyPatches` block for the homebrew-services tap in
  `configuration.nix` (currently disabled).

---

## 6. Dev workflow

- **Rebuild:** `just rebuild` / `./rebuild.sh` / `./r` (flake update + switch);
  `just switch` / `./simple-rebuild.sh` / `./s` (switch only). Both `git add .`,
  run `nix-darwin switch --flake .`, fix repo ownership, auto-commit an empty
  commit tagged with hostname + generation.
- **Format:** `just fmt` (nixfmt + flake-tidy); treefmt via `nix fmt`.
- **Flake input hygiene:** `just tidy` / `tidy-dry` / `tidy-check` (flake-tidy);
  tests via `just tidy-test`.
- **Cleanup:** `./clean` (nix GC, docker prune, cache wipe, trash).
- **Symlinks:** `just link-git` (symlinker.sh). **.opencode sharing:** `just share`
  / `unshare` / `share-status`.
- **MCP:** every server runs under mcpx (launchd agent `org.nixos.mcpx`).
  OAuth for the remote ones: `just mcp-login <name>` / `just context7-login`;
  smoke test: `just mcpx-check`.
- **CI:** `.github/workflows/opencode.yml` (a `/oc` comment-triggered OpenCode
  bot) and `mcpx-nixbuild.yml` (builds the mcpx package on Linux when
  `flake.nix`/`flake.lock` change). Nothing in CI builds the darwin system;
  flake-tidy tests run locally and as the `flake-tidy-tests` flake check.

---

## 7. Repo-local agent skills (`.agents/skills/`)

Repo-local skills live in `.agents/skills/<name>/SKILL.md` — a plain git-tracked
directory using the same layout as the global `~/.agents/skills` that opencode
auto-scans on boot (not a symlink). opencode picks them up automatically; no
config registration needed. This repo ships `nix-config` for repo orientation
and `update-opencode` for updating and repairing the OpenCode/OpenChamber fork
stack from the forks up through this repo's lock.

Three of them are for every session, not only sessions in this repo, so each is
linked by hand into the global folder (`ln -s
~/.config/nix/.agents/skills/<name> ~/.agents/skills/<name>`; nothing in the
flake creates these links): `merge-first` (merge PRs without waiting, only when
asked), `delegate` (models and pools, subagents, separate sessions, nesting and
supervision; `scripts/pools.mjs` prints the live pools and fails when the
skill's table no longer names them) and `mcpx-scripts` (Code Mode and mcpx
scripts that mix MCP servers with shell programs, and adding MCP servers).
`instructions/work-strategies.md` carries the rules; these skills carry the
procedures. Each new skill has `evals/triggers.json` and preserved results from
two rounds of fresh-session trigger tests (`results-2026-11-24-1.json` and
`-2.json`). Re-run with `node scripts/skill-trigger-eval.mjs <triggers.json>`;
that measures first-step loading, not whether the whole task was done correctly.
Misses are kept in the results. The runner's unit tests are
`scripts/skill-trigger-eval.test.mjs`; the pool helper's are
`.agents/skills/delegate/scripts/pools.test.mjs`.

`nix build .#checks.aarch64-darwin.agent-tooling` tests the packaged `record`,
Azure MCP initialization, and Kubernetes reads/Secret refusal against a fake
local API. It needs no cloud credentials or VPN.
