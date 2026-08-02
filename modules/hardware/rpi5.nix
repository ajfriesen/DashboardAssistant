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
{ modulesPath, lib, ... }:
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # In-place updates: rebuild this config from the release tag. No systemd-boot
  # auto-rollback here (extlinux), but manual rollback from the recovery UI works.
  dashboardAssistant.update.installable = true;
  dashboardAssistant.update.flakeAttr = "dashboard-assistant-rpi5";

  # sd-image-aarch64 sets hardware.enableAllHardware, which pulls in a broad
  # initrd module list. That list is what makes the SD card usable (it names the
  # MMC block layer that exposes /dev/mmcblk0, plus the Pi 5's nvme/pcie/rp1
  # modules added by the nixos-hardware profile). The catch is it also names
  # DRM/SoC modules the linux-rpi kernel doesn't ship, so the initrd
  # module-closure fails at build time ("Module dw-hdmi not found"). Rather than
  # clearing the whole list (which also loses mmc_block), disable only the
  # offending modules and keep everything else.
  # See https://github.com/NixOS/nixpkgs/issues/154163
  boot.initrd.availableKernelModules = {
    dw-hdmi = lib.mkForce false;
    dw-mipi-dsi = lib.mkForce false;
    rockchipdrm = lib.mkForce false;
    rockchip-rga = lib.mkForce false;
    phy-rockchip-pcie = lib.mkForce false;
    pcie-rockchip-host = lib.mkForce false;
    pwm-sun4i = lib.mkForce false;
    sun4i-drm = lib.mkForce false;
    sun8i-mixer = lib.mkForce false;
  };

  # Broad Wi-Fi / device firmware, plus the Pi's own firmware blobs.
  hardware.enableRedistributableFirmware = true;

  # The card grows to fill on first boot (like the x86 image), so one image
  # fits any SD card / capacity.
  sdImage.compressImage = true;
}
