# Raspberry Pi 5 (aarch64) hardware profile — SD-card image target.
#
# Built from nixpkgs-unstable (see flake.nix): the Pi 5 kernel/firmware and the
# sd-image-aarch64 [pi5]/bcm2712 support only landed after the pinned 26.05
# release. Board specifics (linux-rpi kernel, RP1 southbridge, PCIe/NVMe, v3d
# GPU) come from the nixos-hardware raspberry-pi-5 module wired in via flake.nix.
#
# Boot chain differs from the Pi 4: the unstable sd-image-aarch64 builder drops a
# generic u-boot.bin on the firmware partition and the Pi 5 firmware chains
# start*.elf → u-boot.bin → extlinux.conf → Linux, so we do NOT need the
# nixos-hardware `firmware.uboot` config.txt kernel= hack the Pi 4 profile uses.
# Like the Pi 4 there's no systemd-boot, so the ABA auto-rollback (bootCounting)
# doesn't apply — manual rollback from the recovery UI still works.
{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # In-place updates: rebuild this config from the release tag. No systemd-boot
  # auto-rollback here (extlinux), but manual rollback from the recovery UI works.
  dashboardAssistant.update.installable = true;
  dashboardAssistant.update.flakeAttr = "dashboard-assistant-rpi5";

  # sd-image-aarch64 sets hardware.enableAllHardware, whose broad initrd module
  # list assumes a mainline kernel and names many modules the stripped linux-rpi
  # kernel doesn't ship (tpm-crb, dw-hdmi, the generic SATA/SCSI drivers, ...), so
  # the initrd module-closure fails at build time ("Module tpm-crb not found").
  # The Pi 5 only needs its own boot modules — mmc_block for the SD card plus the
  # nvme/pcie/rp1 set the nixos-hardware profile already lists, all of which the
  # linux-rpi kernel *does* ship. Rather than chasing an ever-shifting disable
  # list across unstable kernel bumps (as the Pi 4 profile does for its pinned
  # 26.05 kernel), let the closure skip the modules this kernel lacks: the
  # genuinely-needed ones are present and stay included.
  # See boot.initrd.allowMissingModules and https://github.com/NixOS/nixpkgs/issues/154163
  boot.initrd.allowMissingModules = true;

  # Broad Wi-Fi / device firmware, plus the Pi's own firmware blobs.
  hardware.enableRedistributableFirmware = true;

  # The card grows to fill on first boot (like the x86 image), so one image
  # fits any SD card / capacity.
  sdImage.compressImage = true;
}
