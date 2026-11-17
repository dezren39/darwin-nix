{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.meta-quota-export;
in
{
  options.services.meta-quota-export = {
    enable = lib.mkEnableOption "the Meta (dev.meta.ai) quota exporter user service + timer (code#1301 Phase 1, darwin-nix#1776)";
  };

  # Faithful declarative copy of the units hand-installed on amd on
  # 2026-11-01 (~/.config/systemd/user/meta-quota-export.{service,timer}).
  # The exporter script itself lives outside this repo at
  # ~/atlas/meta-quota-export/meta-quota-export.mjs and runs under the
  # system profile node, exactly as the live unit does; this module only
  # gives the units declarative coverage so a rebuild from config alone
  # no longer drops the 15-minute export cadence (code#1301).
  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isLinux) {
    systemd.user.services.meta-quota-export = {
      Unit = {
        Description = "Meta (dev.meta.ai) quota exporter — code#1301 Phase 1";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        TimeoutStartSec = 120;
        ExecStart = "/run/current-system/sw/bin/node %h/atlas/meta-quota-export/meta-quota-export.mjs --cdp-port 19222 --out-dir %h/atlas/meta-quota-export";
      };
    };

    systemd.user.timers.meta-quota-export = {
      Unit.Description = "Run the Meta quota exporter every 15 minutes — code#1301 Phase 1";
      Timer = {
        OnCalendar = "*:0/15";
        RandomizedDelaySec = 20;
        Persistent = true;
        Unit = "meta-quota-export.service";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
