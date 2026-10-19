# DEV ONLY affordances, pulled into the *-dev images only (see flake.nix) and
# never a stable release: root SSH login for VM / field debugging, and a root
# password so the serial console is usable. Declaring these here is what turns
# those paths on at all — modules/core/debug.nix gates each on its own option, so
# a released device ships with no sshd listening and no password on any account.
# (The Chromium CDP port is always open on loopback now — see
# modules/core/kiosk.nix — so it is no longer a dev-only toggle.)
{ lib, config, ... }:
{
  # A serial console on x86, so the labgrid harness can drive an x86 dev image
  # the same way it drives a Pi. The Pi gets this from its hardware module
  # unconditionally (modules/hardware/rpi5.nix sets console=ttyAMA10, the debug
  # connector's UART); x86 sets no `console=` at all, which means a QEMU or a
  # mini-PC serial port receives nothing — no kernel log, no login prompt, and
  # nothing for a harness to talk to. systemd starts serial-getty@ttyS0 by
  # itself once the kernel has a console on it, so the cmdline is the whole fix.
  #
  # DEV IMAGES ONLY, like everything else in this file. A release image gains
  # nothing from it: the console is only useful to someone who also has the root
  # password above, and that is exactly what a release image does not ship.
  #
  # The trade is that kernel messages no longer reach an x86 dev image's screen,
  # since this is the only console= it has. On a bench board that is the right way
  # round — the transcript is the evidence, and nobody is looking at the panel.
  #
  # Guarded on the platform rather than set everywhere, because an aarch64 board
  # has no ttyS0 and an unsatisfiable console= is how you lose the one you have:
  # the *last* console= on the cmdline wins, so appending this on a Pi would
  # silence the UART that works. rpi5.nix uses mkBefore for the same reason.
  boot.kernelParams = lib.optional (config.nixpkgs.hostPlatform.isx86) "console=ttyS0,115200n8";

  dashboardAssistant.debug.rootAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINY2u6VzTMl9DchTo/PojqTibpE3LRxUouwlZ4RSiYjp andrej@gridscale.io"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIE5Wfy20Rsolvzooa4qJ/5uRcZ6cganO7TfCIEiGlbUcAAAABHNzaDo= nixos-desktop-2026-07-11-yubikey3"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIN3NFv4a2U/X6mxDSxJLLZECuyae7a/ijgjD3Lwz8iy2AAAABHNzaDo= nixos-desktop-2026-07-11-yubikey5"

    # The bench key: the one key here that can sign with nobody present, which is
    # what lets the release gate reach a device at all. The two sk- keys above
    # are hardware-backed and need a human to touch a token, and an unsignable
    # key is worse than no key — the failed attempt counts as a failed
    # authentication, and OpenSSH's per-source penalties then drop every
    # connection from that address for an hour. So an automated run holding only
    # those would lock itself out of the board it was trying to test.
    #
    # The private half lives on the bench host and never enters this repository;
    # labgrid/README.md says where. Its one job is the CDP tunnel: the kiosk
    # browser's debugging port is bound to loopback and must stay that way (it is
    # unauthenticated and runs with permissive origins, so exposing it would put
    # a remote-code-execution surface on every dev image on every network), and
    # `ssh -L` over this key is how the gate reaches it without opening anything.
    #
    # DEV IMAGES ONLY, behind the same gate as everything else in this file. A
    # release image carries no key that can sign unattended, and the
    # release-has-no-unattended-access check in flake.nix is what keeps that true.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvE8ZMQXyChCxh021628VNVsNmpzaVBm8wG58DDBBcn bench@keepassxc (dashboard-assistant labgrid)"
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

  # Put the journal back to full fidelity on dev images. modules/core/flash-wear.nix
  # sets this to "info" to spare the SD card on release devices, but the whole
  # point of a bench board is to see everything — and a labgrid run that cannot
  # show a debug line is a run that cannot explain the failure it just caught.
  #
  # Expressed as an option rather than by poking services.journald directly, so
  # flash-wear.nix stays the one place that writes journald.conf; this just
  # states the intent.
  #
  # Storage=volatile is deliberately NOT overridden here. The hourly sync and the
  # shutdown flush are exactly the mechanism tests/first-boot.nix and
  # labgrid/test_first_boot.py assert, so a dev image has to run the same one the
  # shipped image does.
  dashboardAssistant.flashWear.journalMaxLevelStore = "debug";

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
