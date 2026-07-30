# Console installer for the live ISO.
#
# The live USB no longer runs the kiosk itself — it boots straight into this
# service, which asks the operator which disk to erase and then writes the
# persistent system (dashboard-assistant-x86-disk) onto it. The point: you can
# flash the small ISO to a spare USB stick and install onto an internal eMMC you
# have no reader for. Target selection is deliberately interactive (see
# install.sh) — the USB never wipes a machine on its own.
#
# It reuses the exact declarative disko layout and the pre-built system closure
# of the persistent target — the same bits `disko-install` would produce — but
# runs them from paths already baked into the ISO, so the install is fully
# offline (the appliance has no network before it is provisioned).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  sys = config.installer.diskSystem;

  installScript = pkgs.writeShellApplication {
    name = "dashboard-install";
    runtimeInputs = with pkgs; [
      util-linux # lsblk, findmnt, umount
      gnused # retarget the disko script's device
      coreutils # mktemp, sync, sleep
      systemd # udevadm, systemctl
      nixos-install-tools # nixos-install, nixos-enter
      nix # nixos-install shells out to nix-env / nix-store / nix
      bashInteractive # the fail-to-shell fallback
    ];
    # DISKO_SCRIPT: wipes + partitions + mounts the target under /mnt.
    # SRC_DEVICE:   the whole-disk device baked into that script (e.g. /dev/vda),
    #               retargeted to the detected disk at runtime.
    # SYS_TOPLEVEL: the pre-built system to copy onto the fresh filesystems.
    text =
      ''
        readonly DISKO_SCRIPT=${sys.config.system.build.diskoScript}
        readonly SRC_DEVICE=${lib.escapeShellArg sys.config.disko.devices.disk.main.device}
        readonly SYS_TOPLEVEL=${sys.config.system.build.toplevel}
      ''
      + builtins.readFile ./install.sh;
  };
in
{
  options.installer.diskSystem = lib.mkOption {
    type = lib.types.raw;
    description = ''
      The persistent NixOS system (nixosConfigurations.dashboard-assistant-x86-disk)
      to install onto the internal disk. Its diskoScript, disk layout and toplevel
      are pulled into the ISO so the install runs offline.
    '';
  };

  config = {
    # The installer is ephemeral (squashfs + tmpfs), so this only pins module
    # defaults for the live environment; keep it in step with the installed
    # system's stateVersion in modules/core/default.nix.
    system.stateVersion = "26.05";

    # Own tty1 and run once the boot has settled. Type=idle holds ExecStart until
    # the initial job queue drains, so the installer's output isn't interleaved
    # with boot logs; conflicting with getty@tty1 keeps a login prompt off it.
    systemd.services.dashboard-installer = {
      description = "Install Dashboard Assistant to an internal disk";
      wantedBy = [ "multi-user.target" ];
      conflicts = [ "getty@tty1.service" ];
      restartIfChanged = false;
      # Belt-and-suspenders: never reach for a substituter mid-install. The whole
      # closure is local, so an offline box must not block on the network.
      environment.NIX_CONFIG = "substituters =";
      serviceConfig = {
        Type = "idle";
        StandardInput = "tty-force";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        ExecStart = lib.getExe installScript;
      };
    };
  };
}
