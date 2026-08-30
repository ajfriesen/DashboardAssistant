# LAN admin listener: the device's only recovery surface.
#
# The kiosk screen deliberately offers nothing that reconfigures the device — it
# is a wall panel that guests touch, so the bottom bar carries navigation and the
# keyboard only, and the on-device pages are read-only. Rollback and factory reset
# therefore have to arrive over the network, and they live in this daemon rather
# than in the Home Assistant integration because the situations you need them for
# are exactly the ones where Home Assistant is unreachable.
#
# This listener is UNAUTHENTICATED. That is a deliberate trade and it is worth
# stating plainly: the old on-screen panel was authorised by "you reached loopback,
# so you are standing at the device". Nothing replaces that here, so anyone who can
# route to this port can roll the device back or factory-reset it. It is opened on
# the LAN, never forwarded to the internet, and it hands out no credential — see
# handleInfo in daemon/main.go, which no longer returns the API token. Put the
# device on a trusted VLAN if that is not good enough for your network.
#
# See daemon/admin.go.
{
  config,
  lib,
  ...
}:
let
  cfg = config.dashboardAssistant.admin;
in
{
  options.dashboardAssistant.admin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Serve the LAN admin page (rollback, factory reset, read-only device info).
        On by default: with no on-screen config panel, turning this off leaves a
        broken device recoverable only by reflashing its card.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8099;
      description = "TCP port for the LAN admin listener.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Open just the admin port on the LAN (never the internet).
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # Merges with the DASHBOARD_ASSISTANT_ADDR set in daemon.nix.
    systemd.services.dashboard-assistant-daemon.environment = {
      DASHBOARD_ASSISTANT_ADMIN_ADDR = ":${toString cfg.port}";
    };
  };
}
