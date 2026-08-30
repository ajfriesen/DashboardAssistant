# Development-only debugging affordances (root SSH). Do not enable on a real
# device image: declaring a key here turns sshd on.
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
        SSH public keys granted root login for VM/field access (DEV ONLY).
        Declaring any key here also enables sshd; leaving the list empty (the
        default, and what every release image does) means no sshd at all.
      '';
    };
  };

  # sshd is enabled here rather than unconditionally in core/default.nix, so a
  # released device has no ssh port listening. It used to be on everywhere "for
  # field debugging", which left every stable Pi image with a listening sshd that
  # nothing could log into — safe only for as long as no account ever gained a
  # password, and one hashedPassword away from remote root.
  config = lib.mkIf (cfg.rootAuthorizedKeys != [ ]) {
    users.users.root.openssh.authorizedKeys.keys = cfg.rootAuthorizedKeys;

    services.openssh = {
      enable = true;
      # Keys only. The default PermitRootLogin=prohibit-password already allows
      # key auth for root; this just removes the password path entirely.
      settings.PasswordAuthentication = false;
    };
  };
}
