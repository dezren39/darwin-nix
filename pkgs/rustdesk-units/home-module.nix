{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.rustdesk-units;
in
{
  options.services.rustdesk-units = {
    enable = lib.mkEnableOption "the RustDesk service-mode unit and the rd-picker-autogrant unit (darwin-nix#1777)";
  };

  # Faithful declarative copy of the units hand-installed on amd in
  # ~/.config/systemd/user/ (rustdesk.service, rd-picker-autogrant.service),
  # plus the picker script itself, hand-installed at
  # ~/.local/bin/rd-picker-autogrant.py and vendored beside this module
  # byte-for-byte. Declaration only (darwin-nix#1777): enabling this
  # module is a separate, gated step — nothing here restarts RustDesk
  # (it is the fleet's fallback access path to the laptop) and the
  # hand-installed files stay in place until that step verifies the
  # declarative units live.
  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isLinux) {
    home.file.".local/bin/rd-picker-autogrant.py" = {
      source = ./rd-picker-autogrant.py;
      executable = true;
    };

    systemd.user.services.rustdesk = {
      Unit = {
        Description = "RustDesk remote desktop (service mode)";
        After = [ "network.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "/etc/profiles/per-user/user/bin/rustdesk --service";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "XDG_RUNTIME_DIR=/run/user/1337"
          "WAYLAND_DISPLAY=wayland-1"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1337/bus"
        ];
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.rd-picker-autogrant = {
      Unit = {
        Description = "Auto-grant Hyprland share picker for RustDesk sessions (code#5509)";
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "/usr/bin/env python3 %h/.local/bin/rd-picker-autogrant.py";
        Restart = "always";
        RestartSec = 3;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
