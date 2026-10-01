# Development-only debugging affordances: root SSH, and a root password for the
# serial console. Do not enable either on a real device image — declaring one is
# what switches the corresponding access path on.
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

    rootHashedPassword = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "$y$j9T$aNWQGGh1ZPFfeQrQx8YIU0$OYVJGjPkNNUEPFMU3PLpfZE0hZzAaCkg9hAgHnSSHV6";
      description = ''
        Hashed root password for *console* login (DEV ONLY). This is what the
        labgrid hardware harness logs in with over the board's UART — see
        `labgrid/` in this repo. Generate a value with `mkpasswd -m yescrypt`.

        Only the console gains a password: sshd keeps PasswordAuthentication
        off below, so this never becomes a route to remote root. Left null (the
        default, and what every release image does) root has no password at
        all, and the serial console stops at a login prompt nothing can answer.
      '';
    };
  };

  # Each affordance is gated on its own declaration rather than on one shared
  # condition, so a console password does not drag sshd along with it (nor the
  # reverse).
  #
  # sshd is enabled here rather than unconditionally in core/default.nix, so a
  # released device has no ssh port listening. It used to be on everywhere "for
  # field debugging", which left every stable Pi image with a listening sshd that
  # nothing could log into — safe only for as long as no account ever gained a
  # password. That caveat is now load-bearing rather than hypothetical:
  # rootHashedPassword does give root a password, and the
  # PasswordAuthentication = false below is the single line keeping the two from
  # combining into remote root. Do not relax it.
  config = lib.mkMerge [
    (lib.mkIf (cfg.rootAuthorizedKeys != [ ]) {
      users.users.root.openssh.authorizedKeys.keys = cfg.rootAuthorizedKeys;

      services.openssh = {
        enable = true;
        # Keys only. The default PermitRootLogin=prohibit-password already allows
        # key auth for root; this just removes the password path entirely.
        settings.PasswordAuthentication = false;
      };
    })

    (lib.mkIf (cfg.rootHashedPassword != null) {
      users.users.root.hashedPassword = cfg.rootHashedPassword;
    })
  ];
}
