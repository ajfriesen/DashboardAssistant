# btrfs+zstd root for the SD-card images (Pi 4 and Pi 5).
#
# The x86 disk image has run btrfs with compress=zstd since the beginning —
# see modules/hardware/disk-layout.nix, which explains the reasoning: the Nix
# store roughly halves, and it is the single biggest space win on an appliance
# nobody ever prunes by hand. The Pi images never got it, because they come
# from nixpkgs' sd-image.nix, which builds an ext4 root.
#
# Four things are needed to move them across, and the third is the one that
# will brick a board if it is wrong.
#
# 1. Build the root filesystem as btrfs instead of ext4.
# 2. Mount it as btrfs — sd-image.nix hardcodes ext4 at plain priority.
# 3. Teach U-Boot to read btrfs. On the Pi the boot chain is
#      GPU firmware -> u-boot.bin -> extlinux.conf -> Linux
#    and extlinux.conf, the kernel and the initrd all live on the ROOT
#    partition (the FAT partition holds only firmware + u-boot.bin). Stock
#    rpi_arm64_defconfig has ext4/ext2/FAT support and no btrfs, so a btrfs
#    root without this rebuild is a board that never reaches Linux.
# 4. Grow with btrfs on first boot — sd-image.nix's resizer calls resize2fs.
#
# Deliberate divergence from the x86 layout: no subvolumes. disk-layout.nix
# splits @ and @nix, but make-btrfs-fs emits a flat filesystem, and a
# subvolume would be one more thing U-Boot has to resolve before it can find
# /boot. Flat is both the natural output and the smaller risk.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # 1. Build the rootfs with mkfs.btrfs instead of make-ext4-fs. This hook is
  #    provided by sd-image.nix precisely for this; its own example names
  #    make-btrfs-fs.nix. Ours is a vendored copy that also compresses at mkfs
  #    time — see the header of that file for why that matters.
  sdImage.rootFilesystemCreator = ./make-btrfs-fs-zstd.nix;

  # 2. mkForce because sd-image.nix assigns fileSystems."/" at plain priority,
  #    so a normal definition collides instead of overriding.
  #
  #    Nothing else is needed to enable btrfs: boot.initrd.supportedFilesystems
  #    is derived from fileSystems, and nixpkgs' btrfs task module then pulls in
  #    the kernel module and btrfs-progs on the back of that.
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-label/${config.sdImage.rootVolumeLabel}";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "noatime"
    ];
  };

  # 3. U-Boot with btrfs read support. buildUBoot appends extraConfig to
  #    .config after `make <defconfig>`. Spelled out rather than .override'd on
  #    pkgs.ubootRaspberryPiAarch64, because that attribute is a plain
  #    buildUBoot call and does not expose the argument.
  #
  #    Verify after building — this is the cheapest check that the image can
  #    boot at all, and it costs nothing:
  #      strings result/u-boot.bin | grep -i btrfs
  #    On the stock build that is empty.
  hardware.raspberry-pi.firmware.uboot.package = pkgs.buildUBoot {
    defconfig = "rpi_arm64_defconfig";
    extraMeta.platforms = [ "aarch64-linux" ];
    filesToInstall = [ "u-boot.bin" ];
    extraConfig = ''
      CONFIG_FS_BTRFS=y
    '';
  };

  # 4. sd-image.nix's expand-root-partition ends in `resize2fs`, which does
  #    nothing useful on btrfs — the card would silently stay at the shipped
  #    image size forever. Replace the script and keep the rest of the unit
  #    (the ConditionPathExists on the nix-path-registration file is what makes
  #    this a first-boot-only service).
  #
  #    The sfdisk/partprobe half is filesystem-agnostic and is kept verbatim;
  #    only the final resize call differs. Note it resizes the mounted
  #    filesystem by mountpoint, not by device, which is what btrfs expects.
  systemd.services.expand-root-partition.script = lib.mkIf config.sdImage.expandOnBoot (
    lib.mkForce ''
      # Figure out device names for the boot device and root filesystem.
      rootPart=$(${lib.getExe' pkgs.util-linux "findmnt"} -n -o SOURCE /)
      bootDevice=$(${lib.getExe' pkgs.util-linux "lsblk"} -npo PKNAME $rootPart)
      partNum=$(${lib.getExe' pkgs.util-linux "lsblk"} -npo MAJ:MIN $rootPart | ${lib.getExe pkgs.gawk} -F: '{print $2}')

      # Resize the root partition and the filesystem to fit the disk
      echo ",+," | ${lib.getExe' pkgs.util-linux "sfdisk"} -N$partNum --no-reread $bootDevice
      ${lib.getExe' pkgs.parted "partprobe"}
      ${lib.getExe' pkgs.btrfs-progs "btrfs"} filesystem resize max /
    ''
  );
}
