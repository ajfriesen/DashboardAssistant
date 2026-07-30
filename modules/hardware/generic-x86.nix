# Generic x86_64 hardware profile — the bootable installer ISO.
#
# The ISO runs a read-only squashfs root with a tmpfs overlay (ephemeral /
# un-brickable), and boots straight into the console installer (see
# ../installer/installer.nix), which asks which internal disk to erase and writes
# the persistent system onto it. Flash it to a spare USB stick to install onto an
# internal eMMC you have no reader for.
{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/iso-image.nix"
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # Bootable from EFI systems and when dd'd to a USB stick.
  isoImage.makeEfiBootable = true;
  isoImage.makeUsbBootable = true;

  # Force GRUB's text mode. The EFI menu otherwise sets `gfxpayload=keep`, which
  # hands the kernel GRUB's *graphical* GOP mode across the EFI boot handoff.
  # Gemini Lake firmware (ODROID H2 & friends) black-screens on that handoff and
  # bounces back to the boot menu — the menu shows, but selecting an entry never
  # boots. Text mode keeps the handoff on the console and boots reliably.
  isoImage.forceTextMode = true;

  # Broad out-of-the-box hardware/Wi-Fi support on generic devices.
  hardware.enableRedistributableFirmware = true;
}
