{ ... }:
{
  # dashboardAssistant.seed.haUrl = "http://homeassistant:8123/";

  # Import dashboard-assistant.yaml from the ESP (/boot) on first boot and from an
  # inserted USB stick. Required for the seed-file provisioning flow.
  dashboard.configImport.enable = true;

  # Release-safe shared config only. DEV ONLY affordances (diagnostics, Chromium
  # remote debugging, root SSH keys) live in modules/dev.nix and are baked into
  # the *-dev images by flake.nix — never the stable release.
}
