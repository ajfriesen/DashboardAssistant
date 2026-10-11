# Build-time provisioning seed (development / known-network images).
#
# Setting dashboardAssistant.seed.haUrl bakes runtime.env and the `provisioned` marker
# into the image, so first boot skips the waiting splash and goes straight to the
# dashboard. This is Option 3 (pre-seed at flash time) expressed as Nix config.
{ config, lib, ... }:
let
  cfg = config.dashboardAssistant.seed;
in
{
  options.dashboardAssistant.seed = {
    haUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://homeassistant.int.ajfriesen.com";
      description = ''
        If set, pre-seed the Home Assistant URL and mark the device as
        provisioned, so it never waits on the splash for a seed file. Leave null to use
        interactive setup.

        A seed file on the boot medium still overrides this on boot; see
        {option}`dashboard.configImport.enable`.
      '';
    };
  };

  config = lib.mkIf (cfg.haUrl != null) {
    # runtime.env is `f`, create-only: the baked URL is a *default*, written
    # once onto a fresh device and never again. `f+` (truncate every boot)
    # would quietly undo any later change — the card's seed file is applied
    # only when its content hash changes (modules/core/configimport.nix), so
    # from the second boot onward a sysinit-time truncation back to the baked
    # URL would win over the card, the admin page and Home Assistant alike.
    # The flip side is accepted: rebuilding with a *new* baked URL does not
    # update an already-initialised device — reconfigure those via the seed
    # file or the API, which is the documented path anyway.
    # (The dir itself is created by kiosk.nix.)
    #
    # The `provisioned` marker written here no longer gates the seed-file
    # importer — modules/core/configimport.nix dropped that condition in favour
    # of a content-hash check, so a card carrying a dashboard-assistant.yaml is
    # still honoured on an image built with this option set. The precedence is
    # deterministic rather than racy, and it favours the card: these tmpfiles
    # rules run at sysinit, the importer runs at multi-user. That is the
    # intended order — a baked URL is a default, the file in someone's hand is
    # an instruction.
    #
    # What the marker still does is skip the waiting splash (daemon's
    # Provisioned()).
    systemd.tmpfiles.rules = [
      "f /var/lib/dashboard-assistant/runtime.env 0664 dashboard-assistant dashboard-assistant - HA_URL=${cfg.haUrl}"
      "f+ /var/lib/dashboard-assistant/provisioned  0664 dashboard-assistant dashboard-assistant - 1"
    ];
  };
}
