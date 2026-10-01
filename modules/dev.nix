# DEV ONLY affordances, pulled into the *-dev images only (see flake.nix) and
# never a stable release: root SSH login for VM / field debugging, and a root
# password so the serial console is usable. Declaring these here is what turns
# those paths on at all — modules/core/debug.nix gates each on its own option, so
# a released device ships with no sshd listening and no password on any account.
# (The Chromium CDP port is always open on loopback now — see
# modules/core/kiosk.nix — so it is no longer a dev-only toggle.)
{ ... }:
{
  dashboardAssistant.debug.rootAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINY2u6VzTMl9DchTo/PojqTibpE3LRxUouwlZ4RSiYjp andrej@gridscale.io"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIE5Wfy20Rsolvzooa4qJ/5uRcZ6cganO7TfCIEiGlbUcAAAABHNzaDo= nixos-desktop-2026-07-11-yubikey3"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIN3NFv4a2U/X6mxDSxJLLZECuyae7a/ijgjD3Lwz8iy2AAAABHNzaDo= nixos-desktop-2026-07-11-yubikey5"
  ];

  # Root password for the *serial console* only: "dashboard". This is how the
  # labgrid harness (labgrid/) gets a shell on a board on the bench — the UART is
  # the one channel that works before the network does, and without a password it
  # dead-ends at an unanswerable login prompt.
  #
  # Deliberately a known, documented credential rather than a secret: it only
  # exists on images that already carry ssh keys for the same account, it is
  # reachable only by someone holding the board's UART pins, and sshd refuses
  # password auth (modules/core/debug.nix). Release images set nothing here.
  # Regenerate with: mkpasswd -m yescrypt
  dashboardAssistant.debug.rootHashedPassword = "$y$j9T$NPBKZbjANVsl.Uvho0kT00$icGe4UKRBLsGnZ6Q2xcusTOSA6NU5BKC/Ew14NPrry/";

  # Pin the machine ID so a reflashed bench board stays the SAME device in Home
  # Assistant. The daemon derives node_id from /etc/machine-id (daemon/ha.go:77),
  # and systemd generates that from the random pool on first boot — so without
  # this, every `just hw-test` produces a new node_id and HA collects another
  # orphaned Dashboard Assistant device.
  #
  # DEV IMAGES ONLY, and it must stay that way. A release image carrying a fixed
  # machine ID would give every shipped device the same identity, and two of them
  # on one Home Assistant would fight over the same device and entity unique_ids.
  # That is why this lives here and not in modules/core.
  #
  # mode forces a copied regular file rather than the usual symlink into the Nix
  # store: systemd wants to be able to treat /etc/machine-id as a real file.
  environment.etc."machine-id" = {
    text = "0a03370b18534ab8b73e645ac4f95dee\n";
    mode = "0444";
  };

  # A plain, escape-free shell prompt, because the labgrid harness has to find it
  # with a regex. NixOS' default PS1 wraps the prompt in a colour code and an
  # xterm title escape, and readline brackets it with paste markers, so what
  # actually arrives on the console is
  #
  #   ESC[?2004h ESC[1;31m [ ESC]0;root@host: ~BEL root@host:~]# ESC[0m
  #
  # labgrid's ShellDriver matches command output with patterns shaped like
  # `{marker}\s+{prompt}` — it assumes the prompt follows plain whitespace. It
  # cannot match across those escapes, so login succeeds and then every single
  # command times out. No regex for the prompt alone can fix that; the escapes
  # have to stop being emitted. Nothing under test depends on the prompt, and a
  # quiet one is easier to read over a serial line anyway.
  programs.bash.promptInit = ''
    PS1='\u@\h:\w\$ '
  '';
  programs.bash.interactiveShellInit = ''
    # The colour/title escapes come from PS1 above; these come from readline.
    bind 'set enable-bracketed-paste off' 2>/dev/null || true
  '';
}
