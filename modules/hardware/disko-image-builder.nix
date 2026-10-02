# Shared wiring for disko's image builder, for every target that ships a
# disko-built image (x86 disk, Pi 4, Pi 5).
#
# disko builds images by booting a QEMU VM, partitioning a virtio disk inside
# it and running a real `nixos-install` — which is what gets the bootloader
# installed by the normal NixOS path instead of hand-staged. Two things have to
# be fixed up for that VM, and a third only when the image is for a foreign
# architecture.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dashboardAssistant.diskImage;

  # The pkgs instance that runs *inside* the builder VM. Native by default;
  # cross targets point it at the build machine's platform (see builderPkgs).
  basePkgs = if cfg.builderPkgs != null then cfg.builderPkgs else pkgs;

  # 1. disko's in-VM image builder (make-disk-image) builds the VM kernel with
  #    `pkgs.aggregateModules`, whose output has no `.target`. nixpkgs' vmTools
  #    reads `kernel.target` to locate the bootable image, so the image build
  #    fails with "kernel-modules has no target attribute". Re-attach it.
  #    Derived rather than hardcoded, so this is correct whether the builder VM
  #    is x86_64 (bzImage) or aarch64 (Image). Drop this once disko upstream
  #    tracks the vmTools change.
  #
  #    Two lookups because the attribute moved between the channels this flake
  #    pins: `stdenv.hostPlatform.linux-kernel` exists on 26.05 (x86 and Pi 4)
  #    and was removed by 26.11, which instead exposes the image name as a
  #    passthru on the kernel derivation (Pi 5). Neither is present in both, so
  #    hardcoding either one breaks half the targets.
  withKernelTarget =
    p:
    p.extend (
      final: prev: {
        aggregateModules =
          modules:
          (prev.aggregateModules modules).overrideAttrs (old: {
            passthru = (old.passthru or { }) // {
              target = p.stdenv.hostPlatform.linux-kernel.target or p.linuxPackages.kernel.target;
            };
          });
      }
    );
in
{
  options.dashboardAssistant.diskImage.builderPkgs = lib.mkOption {
    type = lib.types.nullOr lib.types.unspecified;
    default = null;
    example = lib.literalExpression "nixpkgs.legacyPackages.x86_64-linux";
    description = ''
      A pkgs instance for the *build machine*, set only when the image is for a
      foreign architecture (the Raspberry Pi targets, built from an x86 box).

      Leaving disko's `imageBuilder.pkgs` at its default on a cross target means
      the builder VM's qemu is itself the foreign architecture, so qemu runs
      under emulation to emulate the guest — disko's own issue tracker calls
      that out: "Builds using the custom QEMU setting would take hours on my
      machine". Pointing this at the build platform instead runs the VM at
      native speed and leaves only `nixos-install`'s chroot emulated, which
      {option}`disko.imageBuilder.enableBinfmt` handles.

      The build host must have binfmt for the target architecture *and*
      `boot.binfmt.preferStaticEmulators = true`; without the latter the chroot
      fails with "chroot: failed to run command '…/activate': No such file or
      directory".
    '';
  };

  config = {
    disko.imageBuilder.pkgs = withKernelTarget basePkgs;

    # 2. disko's builder VM only auto-loads a fixed rootModules list (virtio,
    #    9p, virtiofs, +zfs when used) — btrfs is not among them, and the
    #    minimal VM has no on-demand modprobe. So mounting the freshly-formatted
    #    btrfs root falls back to a FUSE handler and fails ("fuseblk: Unknown
    #    parameter 'subvol'"), aborting the image build.
    disko.imageBuilder.extraRootModules = [ "btrfs" ];

    # 3. Cross only: emulate the target architecture inside the VM so
    #    `nixos-install` can chroot into the installed system to run
    #    `switch-to-configuration boot` (which is what installs systemd-boot).
    #    The builder VM's own kernel has to come from the build platform too,
    #    or disko boots the target's kernel on the wrong architecture.
    disko.imageBuilder.enableBinfmt = lib.mkIf (cfg.builderPkgs != null) true;
    disko.imageBuilder.kernelPackages = lib.mkIf (cfg.builderPkgs != null) basePkgs.linuxPackages;
  };
}
