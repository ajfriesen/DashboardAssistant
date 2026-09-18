# Example per-build overrides.
#
# PREFER A WRAPPER FLAKE OUTSIDE THIS REPO.
#
# Flakes only see git-tracked files, so an override module placed in here has to
# be committed to be picked up — which is exactly how a developer's Sendspin
# server pin once ended up baked into every release image. Keep your overrides
# in your own repo instead:
#
#   # ~/da-dev/flake.nix
#   {
#     inputs.da.url = "path:/path/to/DashboardAssistant/os";
#     outputs = { self, da, ... }: {
#       nixosConfigurations.my-rpi5 =
#         da.nixosConfigurations.dashboard-assistant-rpi5.extendModules {
#           modules = [ ./my-overrides.nix ];
#         };
#     };
#   }
#
# Then `nix build .#nixosConfigurations.my-rpi5.config.system.build.sdImage`.
# Your overrides are tracked in your repo, and a release build here cannot
# pick them up by accident.
#
# If you do want an in-tree override anyway, flake.nix still imports
# modules/local.nix when it exists:
#
#   cp modules/local.example.nix modules/local.nix
#   $EDITOR modules/local.nix
#   git add modules/local.nix          # flakes only see git-tracked files!
#   just build-disk-image
#
# Delete it (and `git rm` it) to return to the interactive on-screen setup.
#
# SECRETS: a LAN URL is fine to commit. Do NOT put credentials/tokens in here —
# a committed Nix file lands in the world-readable Nix store and in git history.
# Seed those via the device's runtime.env or a build-time secret instead.
{ ... }:
{
  # Home Assistant URL to bake in. Presence of this value marks the device
  # "provisioned", so first boot goes straight to the dashboard and skips setup.
  dashboardAssistant.seed.haUrl = "http://homeassistant.local:8123";

  # Chromium's CDP port is always open on 127.0.0.1:9222 (the waybar buttons need
  # it), so you can drive the kiosk browser from host DevTools over `just qemu-ssh`
  # (tunnels 9222) without any extra option.

  # Pin the Sendspin player at one server instead of browsing for
  # _sendspin-server._tcp. Only worth setting on a network where mDNS
  # re-discovery misbehaves — the default is to discover, and pinning this in a
  # shipped image points every device at one operator's hostname.
  # dashboardAssistant.sendspin.server = "ws://homeassistant.local:8927";

  # DEV ONLY: allow root SSH login with these keys (needed for `just qemu-ssh` /
  # `just net-check`; a release image has no sshd at all). Paste your pubkey(s).
  # dashboardAssistant.debug.rootAuthorizedKeys = [
  #   "ssh-ed25519 AAAA... you@host"
  # ];
}
