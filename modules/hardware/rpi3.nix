# Raspberry Pi 3 (aarch64) hardware profile. SD-card image target.
#
# Delivery: a flashable SD image (NixOS's sd-image-aarch64 builder, u-boot +
# extlinux), exactly like the Pi 4/5 targets. Board specifics (linux-rpi kernel,
# wireless firmware, extlinux loader) come from the nixos-hardware
# raspberry-pi-3 module wired in via flake.nix. Like the other Pis there's no
# systemd-boot, so the Automatic Boot Assessment auto-rollback (bootCounting)
# doesn't apply here. Manual rollback from the recovery UI still works.
#
# On aarch64 this board builds linux-rpi from bcm2711_defconfig, the same
# defconfig the Pi 4 uses, but it is still its own kernel derivation: for
# rpiVersion < 4 nixos-hardware adds a postFixup that copies the vendor DTB names
# (bcm2710-rpi-3-b.dtb and friends) to the bcm2837-* names U-Boot expects. So a
# first build compiles a kernel rather than substituting the Pi 4's.
{
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # In-place updates: rebuild this config from the release tag. No systemd-boot
  # auto-rollback here (extlinux), but manual rollback from the recovery UI works.
  dashboardAssistant.update.installable = true;
  dashboardAssistant.update.flakeAttr = "dashboard-assistant-rpi3";

  # Boot chain: the GPU firmware can't read extlinux.conf, so the
  # generic-extlinux-compatible loader (enabled by the nixos-hardware pi3
  # module) needs U-Boot as an intermediary. This copies u-boot.bin onto the
  # firmware partition and points config.txt's kernel= at it (plus arm_64bit=1),
  # so start.elf -> u-boot.bin -> extlinux.conf -> Linux. Without it there is no
  # kernel on the FAT partition and the Pi flashes the green LED 7 times
  # ("kernel image not found") with a black screen, exactly as the Pi 4 profile
  # documents. pkgs.ubootRaspberryPiAarch64, the default package, covers the Pi 3.
  hardware.raspberry-pi.firmware.uboot.enable = true;

  # No initrd module surgery here, unlike the Pi 4 (per-module mkForce false) and
  # the Pi 5 (boot.initrd.allowMissingModules). The nixos-hardware pi3 module
  # already installs a makeModulesClosure { allowMissing = true; } overlay for
  # exactly this problem, so the broad module list sd-image-aarch64 pulls in via
  # hardware.enableAllHardware no longer fails the build on modules the stripped
  # linux-rpi kernel doesn't ship. See https://github.com/NixOS/nixpkgs/issues/154163
  #
  # Broad Wi-Fi / device firmware, plus the Pi's own firmware blobs.
  hardware.enableRedistributableFirmware = true;

  # The nixos-hardware pi3 module, unlike the pi4 one, doesn't pull in the
  # RPi-Distro wireless blobs, and the Pi 3's onboard brcmfmac needs the
  # board-specific NVRAM files to associate. Wi-Fi is how most of these boards
  # reach the setup wizard, so add them explicitly.
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];

  # The Pi 3 has 1 GB of RAM, and nixos-hardware's config.txt defaults enable
  # dtoverlay=vc4-kms-v3d for every board. That overlay pulls in cma-overlay.dts,
  # which sizes CMA at 256 MB: a quarter of this board's memory carved out before
  # the kiosk even starts (the base bcm283x device tree reserves 64 MB). 128 MB is
  # ample for a single 1080p output plus v3d buffers and leaves the browser room.
  # Overriding the whole list keeps the overlay enabled and only adds the parameter.
  hardware.raspberry-pi.configtxt.settings.all.dtoverlay = [ "vc4-kms-v3d,cma-128" ];

  # Cold Chromium pages compress into RAM instead of being reclaimed the hard way.
  # core/memory.nix sets 50 for RAM-rich targets and does so unconditionally, hence
  # mkForce. On a 1 GB board the compressed cushion is worth the CPU it costs.
  zramSwap.memoryPercent = lib.mkForce 100;

  # The card grows to fill on first boot (like the x86 image), so one image
  # fits any SD card / capacity.
  sdImage.compressImage = true;
}
