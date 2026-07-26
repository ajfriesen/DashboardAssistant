{ ... }:
{
  # dashboardAssistant.seed.haUrl = "http://homeassistant:8123/";

  # DEV ONLY.
  dashboardAssistant.diagnostics.enable = true;
  dashboardAssistant.debug.chromiumRemoteDebugging = true;
  dashboardAssistant.debug.rootAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINY2u6VzTMl9DchTo/PojqTibpE3LRxUouwlZ4RSiYjp andrej@gridscale.io"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIE5Wfy20Rsolvzooa4qJ/5uRcZ6cganO7TfCIEiGlbUcAAAABHNzaDo= nixos-desktop-2026-07-11-yubikey3"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIN3NFv4a2U/X6mxDSxJLLZECuyae7a/ijgjD3Lwz8iy2AAAABHNzaDo= nixos-desktop-2026-07-11-yubikey5"
  ];
}
