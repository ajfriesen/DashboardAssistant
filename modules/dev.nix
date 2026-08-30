# DEV ONLY affordances, pulled into the *-dev images only (see flake.nix) and
# never a stable release: root SSH login for VM / field debugging. Declaring keys
# here is what turns sshd on at all — modules/core/debug.nix enables it only when
# this list is non-empty, so a released device ships with no sshd listening. (The
# Chromium CDP port is always open on loopback now — see modules/core/kiosk.nix —
# so it is no longer a dev-only toggle.)
{ ... }:
{
  dashboardAssistant.debug.rootAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINY2u6VzTMl9DchTo/PojqTibpE3LRxUouwlZ4RSiYjp andrej@gridscale.io"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIE5Wfy20Rsolvzooa4qJ/5uRcZ6cganO7TfCIEiGlbUcAAAABHNzaDo= nixos-desktop-2026-07-11-yubikey3"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIN3NFv4a2U/X6mxDSxJLLZECuyae7a/ijgjD3Lwz8iy2AAAABHNzaDo= nixos-desktop-2026-07-11-yubikey5"
  ];
}
