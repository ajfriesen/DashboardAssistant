# Shared Raspberry Pi target: the disko GPT layout plus a UEFI boot chain.
#
# This replaces sd-image-btrfs.nix, and with it the whole nixpkgs sd-image
# builder. The old stack was MBR, a 64 MiB FAT `FIRMWARE` partition that was
# never mounted, a flat btrfs root, and U-Boot reading extlinux.conf off that
# btrfs root — which forced a custom U-Boot built with CONFIG_FS_BTRFS=y, a
# mkForce on fileSystems."/", a swapped rootFilesystemCreator, and a rewritten
# expand-root-partition. All four are gone.
#
# The boot chain now is:
#
#   GPU firmware -> u-boot.bin -> \EFI\BOOT\BOOTAA64.EFI -> systemd-boot -> Linux
#
# U-Boot is still here, but only as a UEFI provider: `rpi_arm64_defconfig` has
# CONFIG_EFI_LOADER=y by default on armv8, and BOOTMETH_EFILOADER "makes the
# bootdevs look for a boot<arch>.efi on each filesystem they scan". So the stock
# pkgs.ubootRaspberryPiAarch64 is enough — verified on a Pi 5, where
# `strings u-boot.bin | grep -ci btrfs` is 0 and the board still boots.
#
# Why bother, when extlinux worked: systemd-boot is what the x86 target already
# uses, and it is where NixOS puts the features this appliance needs —
# boot.loader.systemd-boot.bootCounting (automatic rollback after a failed
# update) exists nowhere else. It is also the boot method nixpkgs sanctions for
# aarch64: "The only supported-by-NixOS boot methods for AArch64 are
# standards-based boot methods, namely UEFI or the pragmatically almost-standard
# extlinux-compatible for U-Boot" (nixpkgs#241534).
#
# Boot counting does work in here, which was not obvious and is the thing that
# kept it switched off (docs/adr/0009). It needs systemd-boot to set
# LoaderBootCountPath, a volatile EFI variable, at runtime — from a loader that
# `bootctl` had to install with --no-variables because U-Boot cannot create a
# Boot#### entry (see canTouchEfiVariables below). `bootctl status` on the bench
# board reports the loader's own "✓ Boot counting", and the cycle itself was
# read off a Pi 5: the image's entry goes onto the card carrying a `+3` counter
# and the running board has none left on any entry. The only thing that removes
# a counter is systemd-bless-boot, and it runs only when the loader set that
# variable — so the loader does set it, --no-variables and all.
# labgrid/test_first_boot.py keeps asking, on the one boot where the answer is
# visible.
#
# Device tree: deliberately left to the GPU firmware. start*.elf merges the
# config.txt dtoverlays (vc4-kms-v3d among them) into the DTB, hands it to
# U-Boot, and U-Boot passes it on through the EFI configuration table — the
# kernel comes up with the right `Machine model` and v3d initialises. So
# systemd-boot's installDeviceTree stays off; turning it on would replace that
# merged DTB with a single flat one and drop every overlay.
{
  config,
  lib,
  ...
}:
let
  fw = config.hardware.raspberry-pi.firmware;

  # Where disko mounts the ESP while building the image.
  espBuildPath = "${config.disko.rootMountPoint}/boot";
in
{
  imports = [
    # One GPT layout for every target: EF00 ESP at /boot, btrfs @ and @nix.
    ./disk-layout.nix
    # VM fix-ups for disko's image builder (kernel target, btrfs module) plus
    # the cross-architecture wiring; the board modules set builderPkgs.
    ./disko-image-builder.nix
    # Automatic GC / store dedup / low-disk safety net. This is a persistent,
    # in-place-updatable target, so without it every update keeps a generation
    # forever and the card fills up.
    ../core/storage.nix
  ];

  # Chainload U-Boot: nixos-hardware copies u-boot.bin onto the firmware
  # partition and points config.txt's `kernel=` at it (plus arm_64bit=1). Still
  # required — it is U-Boot that provides the UEFI environment systemd-boot runs
  # in. Without it there is no kernel on the FAT partition and the Pi flashes
  # the green LED 7 times ("kernel image not found") with a black screen.
  #
  # Note this is the *stock* package now; sd-image-btrfs.nix used to override
  # it with a btrfs-enabled rebuild, which is unnecessary once the kernel and
  # loader config live on the ESP rather than on the btrfs root.
  hardware.raspberry-pi.firmware.uboot.enable = true;

  # Keep the firmware partition current on a running system: nixos-hardware
  # installs an activation script that repopulates `path` on every system
  # switch, so an OTA update that bumps raspberrypifw or U-Boot actually lands
  # on the card. It is guarded by `mountpoint -q`, and points at /boot rather
  # than the sd-image's /boot/firmware because there is only one FAT partition
  # now and it *is* /boot.
  hardware.raspberry-pi.firmware.enable = true;
  hardware.raspberry-pi.firmware.path = "/boot";

  # ...and stage the same files into the image at build time. The activation
  # script above cannot do this job: disko builds the image by running
  # `nixos-install`, which ends in `switch-to-configuration boot`, and that
  # installs the bootloader and then exits *before* activation
  # ("if *action == Action::Boot { std::process::exit(0); }"). So a freshly
  # built image would have systemd-boot but no config.txt and no u-boot.bin —
  # an unbootable board.
  #
  # Plain `lib.types.lines` run by the builder VM's own bash, on purpose: the VM
  # is the build platform (see disko-image-builder.nix), so a hook built from
  # `pkgs.writeScript` would be a foreign-architecture script needing binfmt.
  # cp/mkdir are on the VM's PATH already.
  #
  # Deliberately simpler than nixos-hardware's installer: this runs against a
  # freshly formatted, empty ESP, so there is nothing to prune and no partially
  # written file to guard against. The pruning/temp-rename logic matters only
  # when rewriting a live partition, which is exactly where the activation
  # script above runs instead.
  #
  # The subshell with `set +f` is load-bearing, not style. disko runs its
  # generated create/mount scripts under `set -efux`, and that `-f` disables
  # pathname expansion — so a glob in a hook is passed through to the command
  # verbatim and the first one fails with
  #
  #   cp: cannot stat '…/share/raspberrypi/boot/start*.elf': No such file
  #
  # even though eight such files are sitting right there. Re-enabled inside a
  # subshell so it cannot leak into the rest of disko's script; `set -e` still
  # applies, so a failing cp in here still aborts the image build.
  #
  # And the copy stays selective rather than `cp -r "$fwboot"/.`: the firmware
  # package is 78 MiB, ~55 MiB of which is Raspberry Pi OS's own kernel images
  # (kernel8.img, kernel_2712.img, ...). config.txt points `kernel=` at
  # u-boot.bin, so none of them would ever be read — they would just be the
  # largest thing on the ESP.
  disko.devices.disk.main.content.partitions.ESP.content.postMountHook = ''
    echo "rpi-firmware: staging the Raspberry Pi boot chain into ${espBuildPath}"
    (
      set +f
      fwboot=${fw.package}/share/raspberrypi/boot
      mkdir -p ${espBuildPath}/overlays
      cp "$fwboot"/bootcode.bin ${espBuildPath}/
      cp "$fwboot"/start*.elf "$fwboot"/fixup*.dat ${espBuildPath}/
      cp "$fwboot"/*.dtb ${espBuildPath}/
      cp "$fwboot"/overlays/* ${espBuildPath}/overlays/
      cp ${fw.uboot.package}/u-boot.bin ${espBuildPath}/u-boot.bin
      cp ${config.hardware.raspberry-pi.configtxt.file} ${espBuildPath}/config.txt
    )
  '';

  # systemd-boot, configured exactly as the x86 target is.
  #
  # canTouchEfiVariables = false is not a preference here, it is forced by
  # U-Boot: "As of U-Boot v2020.10 UEFI variables cannot be set at runtime", so
  # `bootctl` cannot create a Boot#### entry and the builder must pass
  # --no-variables. What boots instead is the removable fallback
  # \EFI\BOOT\BOOTAA64.EFI, which is precisely what U-Boot's BOOTMETH_EFILOADER
  # scans for — and `bootctl install` writes it unprompted. The x86 target
  # already relies on the same fallback for unrelated ODROID firmware reasons.
  #
  # configurationLimit bounds how many generations get boot entries + kernels
  # copied into the ESP, so /boot cannot fill up. It matters more here than on
  # x86: a kernel is ~37 MiB and an initrd ~30 MiB, so each retained generation
  # costs ~70 MiB of the 512 MiB partition. GC (storage.nix) prunes the matching
  # store paths; together they keep the card bounded.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 3;
  boot.loader.efi.canTouchEfiVariables = false;

  # Leave the device tree to the GPU firmware (see the header). This is already
  # the default — it keys off hardware.deviceTree.name, which the nixos-hardware
  # board profiles do not set — but it is load-bearing enough to state.
  boot.loader.systemd-boot.installDeviceTree = false;

  # extlinux is what nixos-hardware's board profiles switch on by default
  # (`loader.generic-extlinux-compatible.enable = lib.mkDefault true`). mkForce
  # rather than a plain false so the intent is unmistakable: two bootloaders
  # both writing into /boot would be a coin toss over which one U-Boot picks.
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

  # Grow the root partition to fill the actual card in early boot, paired with
  # x-systemd.growfs on / (disk-layout.nix) — same mechanism as x86, replacing
  # the sd-image `expand-root-partition` unit and its resize2fs-vs-btrfs
  # override. One image therefore fits any card.
  boot.growPartition = true;

  # The SD card itself. The host controllers are built into the linux-rpi
  # kernel, but the block layer that exposes the card as /dev/mmcblk0 is a
  # module (CONFIG_MMC_BLOCK=m) — without it stage 1 never finds the root
  # device and the boot times out in emergency mode. This used to come in
  # wholesale via sd-image-aarch64's hardware.enableAllHardware, which also
  # dragged in DRM/SoC modules the linux-rpi kernel does not ship and which the
  # board profiles then had to disable one by one.
  boot.initrd.availableKernelModules = [ "mmc_block" ];

  # Keep the screen as /dev/console. The *last* console= on the cmdline is the
  # one the kernel opens as /dev/console, so this has to stay at plain priority,
  # after any board-specific serial console added with mkBefore (rpi5.nix adds
  # the debug UART that way).
  #
  # It used to arrive for free: sd-image-aarch64 put
  # `console=ttyS0 console=ttyAMA0 console=tty0` on every image, and tty0 came
  # last. Dropping that module took the whole list with it, which left the Pi 5
  # with only its debug UART — so a release board with nothing attached to the
  # 3-pin connector would write kernel output, and any emergency-mode prompt,
  # to a port nobody is reading, with a blank screen. Only tty0 is restored
  # here; the two GPIO-header UARTs were never reachable on these boards anyway
  # (and config.txt disables the Pi 5's outright with `[pi5] enable_uart=0`).
  boot.kernelParams = [ "console=tty0" ];

  # Broad Wi-Fi / device firmware, plus the Pi's own firmware blobs.
  hardware.enableRedistributableFirmware = true;
}
