# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Runs the mcpx daemon on ~/.config/mcpx/config.json, the path every client
# names, instead of the canonical darwin module's store file.
#
# mcpx keys a daemon's socket on the config path as given, not its content
# and not its symlink target. Measured 2026-11-22 against the running
# daemon (started with --config /nix/store/gmhkcrfw...-mcpx-config.json):
#   mcpx --config <that store path> ls                       -> exit 0
#   mcpx --config <link to that same store path> ls          -> exit 1
#   mcpx --config ~/.config/mcpx/config.json ls (same bytes) -> exit 1
# so mcp-clients.py's --config (Copilot CLI, Claude Code, Codex, Zed) and
# anything using the home path got "no daemon reachable". The module's
# configFile is readOnly, so this replaces only the agent's program: the
# module still renders, installs and restarts its own wrapper, and its
# restart marker (set whenever the mcpx build or config changes) restarts
# this agent too. homeUser.nix (mcpxConfig) writes the real file this
# reads, and a config change is also picked up in place by
# daemon.watchConfig.
#
# Remove this file once the module accepts a config path for the daemon.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.mcpx;
  user = config.system.primaryUser;
  home = config.users.users.${user}.home;
  clientConfig = "${home}/.config/mcpx/config.json";
  agentPath = "/usr/local/libexec/mcpx-user/mcpx";
  agent = pkgs.writeShellScript "mcpx" ''
    cfg='${clientConfig}'
    # Written by home-manager; absent only before the first activation.
    # Exit so KeepAlive retries rather than start on some other config.
    if [ ! -r "$cfg" ]; then
      echo "mcpx agent: $cfg is not readable; exiting so launchd retries" >&2
      exit 1
    fi
    ${cfg.package}/bin/mcpx --config "$cfg" stop || true
    exec ${cfg.package}/bin/mcpx daemon --config "$cfg"
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Same basename as the module's copy, so macOS still lists it as "mcpx".
    launchd.user.agents.mcpx.serviceConfig.ProgramArguments = lib.mkForce [ agentPath ];
    launchd.user.envVariables.MCPX_CONFIG = lib.mkForce clientConfig;
    # launchctl setenv is gone after a reboot; login shells need it too.
    environment.variables.MCPX_CONFIG = clientConfig;

    # Install before launchd is set up; a changed copy uses the module's
    # marker so the module's postActivation restarts the agent.
    system.activationScripts.extraActivation.text = lib.mkAfter ''
      # mcpx-user-agent-install-begin
      if ! /usr/bin/cmp -s ${agent} ${agentPath}; then
        echo "installing ${agentPath}" >&2
        /bin/mkdir -p "$(/usr/bin/dirname ${agentPath})"
        /usr/bin/install -o root -g wheel -m 0755 ${agent} ${agentPath}.tmp
        /bin/mv -f ${agentPath}.tmp ${agentPath}
        /usr/bin/touch /usr/local/libexec/mcpx/mcpx.restart-pending
      fi
      # mcpx-user-agent-install-end
    '';
  };
}
