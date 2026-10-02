# Declarative disk layout for every persistent target, consumed by disko. One
# layout, parameterised per board — the x86 disk image and both Raspberry Pi
# SD images are the same two partitions, so a change to either cannot drift
# apart from the other.
#
# This replaces the ext4 root that make-disk-image produced (make-disk-image can
# only emit ext4 for a partitioned image). btrfs with `compress=zstd` roughly
# halves the on-disk footprint of the Nix store — the single biggest space win
# for an appliance nobody prunes by hand.
#
# `device` is only the default target used when building the image; a real
# install onto someone else's board overrides it, e.g.
#   disko-install --flake .#dashboard-x86-disk --disk main /dev/nvme0n1
#
# Two subvolumes: @ (root, incl. /var/lib/dashboard-assistant state) and @nix
# (the store). Splitting them keeps the door open for the
# impermanence/erase-your-darlings plan later without a reformat.
#
# Partition 1 is an EFI system partition (EF00) on every target, including the
# Pi. That is not cosmetic uniformity — `bootctl` refuses to install into
# anything else:
#
#   # bootctl --esp-path=/mnt/esp status
#   File system "/dev/mmcblk0p1" has wrong type for an EFI System Partition (ESP).
#
# and `boot.loader.systemd-boot` runs `bootctl install`. The Pi's boot ROM reads
# an ESP-typed GPT partition happily (verified on a Pi 5 with 2026/05/26
# firmware), so rpi-eeprom#558 — where the bootloader matches the ESP GUID and
# then fails "Unable to read partition as FAT" — did not reproduce. If it ever
# does on an older EEPROM, Microsoft basic data (`0700`) is the workaround, at
# the cost of needing SYSTEMD_RELAX_ESP_CHECKS for bootctl.
#
# On the Pi this one partition carries *both* the Raspberry Pi boot chain
# (config.txt, u-boot.bin, the vendor DTBs and overlays/) and the usual ESP
# contents (EFI/BOOT/BOOTAA64.EFI, loader/entries, the kernels). Raspberry Pi OS
# puts everything in one FAT partition too. That is what collapses the old
# separate `FIRMWARE` partition into `/boot` and lets the seed-file importer and
# the docs stop special-casing the Pi.
{ config, lib, ... }:
let
  cfg = config.dashboardAssistant.diskLayout;
in
{
  options.dashboardAssistant.diskLayout = {
    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/vda";
      description = ''
        Disk the image is built against. disko's image builder always presents
        the target as a virtio disk inside its VM, so this is the same for every
        board; only a real `disko-install` onto physical media overrides it.
      '';
    };

    imageName = lib.mkOption {
      type = lib.types.str;
      default = "dashboard-assistant";
      description = ''
        Basename of the built image, i.e. `<imageName>.raw` in the derivation
        output. Per-board so the artifacts of two targets can sit side by side.
      '';
    };

    imageSize = lib.mkOption {
      type = lib.types.strMatching "[0-9]+[KMGTP]?";
      default = "4G";
      description = ''
        Size of the *built* image, not of the medium. Kept just big enough for
        the initial closure: the root partition is grown to fill the real disk
        on first boot (`boot.growPartition` plus the `x-systemd.growfs` mount
        option on `/`), so one image fits a 16 GB SD card and a 500 GB SSD
        alike.

        disko has no auto-sizing (see its docs: "The auto-resizing feature is
        currently not available in Disko"), so this is a hand-maintained number
        and a closure that outgrows it fails the image build.
      '';
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = ''
        Size of the EFI system partition mounted at `/boot`.

        512 MiB is sized for the Pi, which is the demanding case: ~25 MiB of
        Raspberry Pi firmware plus a kernel (~37 MiB) and initrd (~30 MiB) per
        retained generation. With {option}`boot.loader.systemd-boot.configurationLimit`
        at 3 that is roughly 230 MiB, and the x86 target has been on 512 MiB
        since the beginning — so one number covers both.
      '';
    };
  };

  config.disko.devices.disk.main = {
    type = "disk";
    inherit (cfg) device imageName imageSize;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          name = "ESP";
          start = "1M";
          # `size`, not `end`: disko turns size into sgdisk's `+N` relative
          # end, so the partition really is espSize long. An absolute end here
          # would silently shave the 1 MiB start offset off the option value.
          size = cfg.espSize;
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "/@" = {
                mountpoint = "/";
                # x-systemd.growfs: after the partition is grown, expand the
                # btrfs to fill it (one resize grows the whole fs incl. @nix).
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                  "x-systemd.growfs"
                ];
              };
              "/@nix" = {
                mountpoint = "/nix";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
            };
          };
        };
      };
    };
  };
}
