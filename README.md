# nix

Single-user **nix-darwin + home-manager + nix-homebrew** flake for an Apple
Silicon Mac, plus the local AI-tooling setup (OpenCode / OpenChamber /
Copilot / mcpx) that runs on it. This README is the front door;
[ARCHITECTURE.md](ARCHITECTURE.md) is the full orientation.

## Daily commands

| Command | What it does |
| ------- | ------------ |
| `./r` | Full rebuild: stage new files, update flake inputs, build, switch (`rebuild.sh`) |
| `./s` | Build + activate without a flake update (`simple-rebuild.sh`) |
| `just build` / `just activate [GENERATION]` | The same build split by privilege: build needs no sudo, activate does |
| `just generations` | List the generations `just activate N` can roll back to |
| `./adopt [TEMPLATE]` | Add this Mac as a darwin host (`pkgs/adopt`) |
| `just --list` | Every recipe, grouped — the rest of the interface lives there |

## Where things live

- [ARCHITECTURE.md](ARCHITECTURE.md) — layout, features, and how the pieces fit
- [ROADMAP.md](ROADMAP.md) and [planning/](planning/) — intent and plans (a roadmap row is not a go-ahead)
- [docs/](docs/) — topic notes: [services](docs/services.md), [MCP](docs/mcp.md), SidePulse
- [.github/ci-policy.md](.github/ci-policy.md) — what CI runs, when, and why

## Checking a change

```
nix flake check
just fmt   # nix fmt + flake-tidy
```

CI is main-only (see the policy above), so run the checks locally before
merging.

## Notes

Fresh single-user Mac install, before nix is on `PATH`:

```
path=("$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin" "/run/current-system/sw/bin" "$path[@]")
```

single-user mac install

TODO: integrate and make multi-user
TODO: split darwin only separate from linux-compatible

SPDX-License-Identifier: MIT OR Apache-2.0
