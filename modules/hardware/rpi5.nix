# Raspberry Pi 5 (aarch64) hardware profile — SD-card image target.
#
# Built from nixpkgs-unstable (see flake.nix): the Pi 5 kernel/firmware bits are
# newer than the pinned 26.05. Board specifics (linux-rpi kernel, RP1
# southbridge, PCIe/NVMe, v3d GPU) come from the nixos-hardware raspberry-pi-5
# module wired in via flake.nix.
#
# Layout and boot chain are shared with the Pi 4 and, as far as the partition
# table goes, with x86 — see modules/hardware/rpi-disk-image.nix and
# modules/hardware/disk-layout.nix.
{
  lib,
  pkgsBuild,
  ...
}:
{
  imports = [
    # disko GPT layout + U-Boot-as-UEFI + systemd-boot, shared with the Pi 4.
    ./rpi-disk-image.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # Build the image in a native x86 VM and emulate only nixos-install's chroot.
  # See dashboardAssistant.diskImage.builderPkgs for why this is not optional.
  dashboardAssistant.diskImage.builderPkgs = pkgsBuild;
  dashboardAssistant.diskLayout.imageName = "dashboard-assistant-rpi5";

  # In-place updates: rebuild this config from the release tag. Unlike the old
  # extlinux images this one can also roll back by itself once boot counting is
  # switched on — systemd-boot provides it (see rpi-disk-image.nix).
  dashboardAssistant.update.installable = true;
  dashboardAssistant.update.flakeAttr = "dashboard-assistant-rpi5";

  # Put the kernel console on the Pi 5's dedicated debug UART, which is where a
  # Debug Probe on the 3-pin connector listens — and where the boot ROM, the RP1
  # firmware and U-Boot already print.
  #
  # The device tree is unambiguous:
  #
  #   uart10 = /soc@107c000000/serial@7d001000   <- the debug connector, pl011
  #   uart0  = /axi/pcie@.../rp1/serial@30000    <- GPIO 14/15
  #   console     = ...serial@7d001000
  #   stdout-path = "serial10:115200n8"
  #
  # so the debug UART is ttyAMA10, and ttyAMA0 is the GPIO header's — which
  # config.txt switches off anyway ("[pi5] enable_uart=0"). An explicit console=
  # on the cmdline overrides the DT's stdout-path, so without this the kernel
  # says nothing at all on the probe: U-Boot narrates the whole boot, then the
  # log stops dead at "Starting kernel ...". systemd's getty generator also
  # reads this list, so adding it is what puts a login prompt on the probe.
  #
  # This survives the move to systemd-boot: the firmware-merged DTB still
  # reaches the kernel through U-Boot's EFI handoff, and `printk: console
  # [ttyAMA10] enabled` was verified on the bench.
  #
  # mkBefore to stay ahead of any defaults: the *last* console= becomes
  # /dev/console, and that should remain tty0.
  boot.kernelParams = lib.mkBefore [ "console=ttyAMA10,115200n8" ];

  # The stripped linux-rpi kernel does not ship every module the nixos-hardware
  # profile names (tpm-crb, dw-hdmi, the generic SATA/SCSI drivers, ...), so the
  # initrd module-closure would fail at build time ("Module tpm-crb not found").
  # Rather than chasing an ever-shifting disable list across unstable kernel
  # bumps, let the closure skip the modules this kernel lacks: the genuinely
  # needed ones are present and stay included.
  # See boot.initrd.allowMissingModules and https://github.com/NixOS/nixpkgs/issues/154163
  boot.initrd.allowMissingModules = true;
}
