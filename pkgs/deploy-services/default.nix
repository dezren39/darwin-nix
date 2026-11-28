# SPDX-License-Identifier: MIT OR Apache-2.0
#
# deploy-openchamber + deploy-mcpx — the option-(c) deploy apps for
# the two store-pinned user services (dezren39/darwin-nix#1393, epic
# #973).
#
# Each app is a thin wrapper that bakes its service's parameters
# into the environment and execs the shared core
# (./deploy-service.sh): validate the target, atomically repoint the
# stable entrypoint, restart the unit, health-check, roll back on a
# failed health check. The stable entrypoints and the contract they
# implement live in developing-today/code#14187
# (nixos/home/stable-entrypoints.nix there):
#
#   openchamber.service  ~/.local/state/openchamber/start
#   mcpx.service         ~/.local/state/mcpx/bin/mcpx
#
# The targets are THIS flake's builds — that is the point of a
# deploy app: `nix run .#deploy-mcpx` realises this flake's pinned
# mcpx and moves the service onto it without a Home Manager switch.
# A later switch repoints the links at the code flake's generation
# again (the activation only moves a link whose target changed);
# deploys of the same link are serialized by the core's per-link
# flock (#2307), and the unit files never change either way.
{
  pkgs,
  openchamber-start,
  mcpx,
}:
let
  core = pkgs.writeShellApplication {
    name = "deploy-service-core";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      util-linux # flock, for the core's per-link deploy lock (#2307)
    ];
    text = builtins.readFile ./deploy-service.sh;
  };

  mkDeployApp =
    {
      name,
      unit,
      linkRel,
      target,
      health,
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ core ];
      text = ''
        export DEPLOY_NAME="${name}"
        export DEPLOY_UNIT="${unit}"
        export DEPLOY_LINK_REL="${linkRel}"
        export DEPLOY_TARGET="${target}"
        export DEPLOY_HEALTH="${health}"
        exec deploy-service-core "$@"
      '';
    };
in
{
  deploy-openchamber = mkDeployApp {
    name = "deploy-openchamber";
    unit = "openchamber.service";
    linkRel = "openchamber/start";
    target = "${openchamber-start}/bin/openchamber-start";
    health = "openchamber";
  };

  deploy-mcpx = mkDeployApp {
    name = "deploy-mcpx";
    unit = "mcpx.service";
    linkRel = "mcpx/bin/mcpx";
    target = "${mcpx}/bin/mcpx";
    health = "mcpx";
  };
}
