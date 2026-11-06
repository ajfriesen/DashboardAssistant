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
# Three subvolumes: @ (root, incl. /var/lib/dashboard-assistant state), @nix
# (the store) and @swap (a swap file behind zram). Splitting @ and @nix keeps
# the door open for the impermanence/erase-your-darlings plan later without a
# reformat; @swap is its own because btrfs refuses to swap to a file in a
# subvolume that is snapshotted, and keeping it out of @ keeps it out of any
# snapshot of the root.
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
      default = "5G";
      description = ''
        Size of the *built* image, not of the medium. Kept just big enough for
        the initial closure: the root partition is grown to fill the real disk
        on first boot (`boot.growPartition` plus the `x-systemd.growfs` mount
        option on `/`), so one image fits a 16 GB SD card and a 500 GB SSD
        alike. It includes the {option}`espSize` ESP, so the two move together:
        5G is the ESP plus a 4 GiB root.

        disko has no auto-sizing (see its docs: "The auto-resizing feature is
        currently not available in Disko"), so this is a hand-maintained number
        and a closure that outgrows it fails the image build.
      '';
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = ''
        Size of the EFI system partition mounted at `/boot`.

        The Pi is the demanding case: ~25 MiB of Raspberry Pi firmware plus a
        kernel (~37 MiB) and initrd (~30 MiB) per retained generation. With
        {option}`boot.loader.systemd-boot.configurationLimit` at 3 that is
        roughly 230 MiB. 1 GiB is the size distributions now recommend for an
        ESP that doubles as `/boot`, and leaves room for unified kernel images
        or more generations.

        Devices flashed before the bump keep their 512 MiB ESP: an update
        cannot resize it, because the root partition follows it. Until those
        devices are reflashed, what lands on `/boot` must still fit 512 MiB.
      '';
    };
  };

  # growpart keeps its scratch files in $TMPDIR, and its unit is ordered
  # `After=-.mount` with DefaultDependencies=false — so it runs while / is the
  # only thing mounted and has no ordering relationship to tmp.mount at all.
  # With boot.tmp.useTmpfs (modules/core/flash-wear.nix) that is a race it
  # loses about half the time: `mktemp -d` lands on the root filesystem, the
  # tmpfs is mounted over /tmp a second later, and growpart's own directory
  # becomes unreachable mid-run:
  #
  #   .growpart-wrapped: line 714: /tmp/.growpart-wrapped.XXX/pt_update.err:
  #       No such file or directory
  #   FAILED: pt_resize failed            (exit 2; the unit allows only 0 and 1)
  #
  # The unit then fails, systemd-growfs-root.service is ordered after it and
  # does not finish the job, and the device ships with a 3.5 GB root on a 16 GB
  # card — degraded until the next boot, where growpart exits 1 for NOCHANGE,
  # which *is* allowed, and the whole thing goes green and hides.
  #
  # /run is a tmpfs mounted in the initrd and never mounted over, so pointing
  # TMPDIR at it removes the race without touching the boot ordering. Caught on
  # the bench by test_growpart_succeeded; measured timings are in
  # labgrid/README.md. An upstream fix belongs in nixpkgs' grow-partition.nix,
  # which should either order itself before tmp.mount or stop using /tmp.
  config.systemd.services.growpart.environment.TMPDIR = "/run";

  # The swap file behind zram, on its own @swap subvolume (see the header).
  # NixOS creates it on first boot with `btrfs filesystem mkswapfile`, which
  # makes it NOCOW and so uncompressed, as btrfs requires of a swap file. Its
  # priority is below zram's (modules/core/memory.nix), so the kernel writes
  # here only once compressed RAM is full: a last resort that costs flash
  # writes, in exchange for not killing the browser on a 2 GB board.
  config.swapDevices = [
    {
      device = "/swap/swapfile";
      size = 1024; # MiB
      priority = 10;
    }
  ];
  # The built image has well under a gigabyte free on its root; the file only
  # fits once growpart and growfs have expanded it to the real medium.
  config.systemd.services.mkswap-swap-swapfile.after = [
    "growpart.service"
    "systemd-growfs-root.service"
  ];

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
              # Only the subvolume is made here, not the file: disko's own
              # `swap.swapfile` would allocate it at image build time and put a
              # gigabyte of zeros into every image. swapDevices below creates
              # it on first boot instead.
              "/@swap" = {
                mountpoint = "/swap";
                mountOptions = [ "noatime" ];
              };
            };
          };
        };
      };
    };
  };
}
