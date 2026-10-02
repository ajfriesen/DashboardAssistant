# Raspberry Pi 4 (aarch64) hardware profile — SD-card image target.
#
# Board specifics (firmware, kernel, v3d GPU) come from the nixos-hardware
# raspberry-pi-4 module wired in via flake.nix. Layout and boot chain are shared
# with the Pi 5 and, as far as the partition table goes, with x86 — see
# modules/hardware/rpi-disk-image.nix and modules/hardware/disk-layout.nix.
#
# One Pi 4-specific consequence of the pure-GPT table: the board needs a
# bootloader EEPROM from 2020-09-14 or later ("Add support GPT and Hybrid MBR
# partition tables"). Older boards will not boot this image, and because
# recovery.bin is read by the mask ROM — which understands neither GPT nor an
# EFI partition type — this card cannot update the EEPROM either. Such a board
# needs a Raspberry Pi OS card first; see docs/flash/flash.md.
{ pkgsBuild, ... }:
{
  imports = [
    # disko GPT layout + U-Boot-as-UEFI + systemd-boot, shared with the Pi 5.
    ./rpi-disk-image.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # Build the image in a native x86 VM and emulate only nixos-install's chroot.
  # See dashboardAssistant.diskImage.builderPkgs for why this is not optional.
  dashboardAssistant.diskImage.builderPkgs = pkgsBuild;
  dashboardAssistant.diskLayout.imageName = "dashboard-assistant-rpi4";

  # In-place updates: rebuild this config from the release tag.
  dashboardAssistant.update.installable = true;
  dashboardAssistant.update.flakeAttr = "dashboard-assistant-rpi4";

  # v3d GPU via the fake-KMS overlay, so Wayland/Chromium get hardware
  # acceleration instead of falling back to slow software rendering. This is a
  # config.txt dtoverlay, which is why the device tree has to stay the
  # firmware's to merge — see the header of rpi-disk-image.nix.
  hardware.raspberry-pi."4".fkms-3d.enable = true;
}
