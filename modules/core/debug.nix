# Development-only debugging affordances. Do not enable on a real device image.
{ config, lib, ... }:
let
  cfg = config.dashboardAssistant.debug;
in
{
  options.dashboardAssistant.debug = {
    rootAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIN3NFv4a2U/X6mxDSxJLLZECuyae7a/ijgjD3Lwz8iy2AAAABHNzaDo= nixos-desktop-2026-07-11-yubikey5"
      ];
      description = ''
        SSH public keys granted root login for VM/field access (DEV ONLY). Key
        auth works under the default PermitRootLogin=prohibit-password, so no
        further sshd changes are needed.
      '';
    };
  };

  config = lib.mkIf (cfg.rootAuthorizedKeys != [ ]) {
    users.users.root.openssh.authorizedKeys.keys = cfg.rootAuthorizedKeys;
  };
}
