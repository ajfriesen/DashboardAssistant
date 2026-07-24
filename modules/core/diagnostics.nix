# Opt-in LAN diagnostics: the daemon serves a redacted, code-gated view of recent
# logs on a dedicated port, so a user can hand logs to the maintainer from their
# own phone/laptop — the kiosk has no SSH and is locked to Home Assistant.
#
# Off by default. When enabled it opens a single LAN port (not the internet) and
# grants the daemon journal read access. The main :8080 admin surface stays
# loopback-only; access to the diagnostics logs is gated by a one-time code shown
# on the device (Config -> Diagnostics). See daemon/diag.go.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dashboardAssistant.diagnostics;
in
{
  options.dashboardAssistant.diagnostics = {
    enable = lib.mkEnableOption ''
      a LAN-reachable, secret-redacted diagnostics page (opt-in). When on, the
      daemon opens a dedicated port and can read the journal; a one-time code
      shown on the device gates access. Only enable on trusted networks
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 8099;
      description = "TCP port for the LAN diagnostics listener.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Let the daemon read the journal it exposes (redacted) over the diag page.
    users.users.dashboard-assistant.extraGroups = [ "systemd-journal" ];

    # Open just the diagnostics port on the LAN (never the internet).
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # Merges with the DASHBOARD_ASSISTANT_ADDR set in daemon.nix.
    systemd.services.dashboard-assistant-daemon.environment = {
      DASHBOARD_ASSISTANT_DIAG = "1";
      DASHBOARD_ASSISTANT_DIAG_ADDR = ":${toString cfg.port}";
      DASHBOARD_ASSISTANT_JOURNALCTL = "${pkgs.systemd}/bin/journalctl";
    };
  };
}
