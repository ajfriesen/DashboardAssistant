# On-disk install target (e.g. ODROID H2 with a SATA SSD).
#
# Unlike the live ISO, this is a persistent system with a real bootloader, so it
# boots from a fixed SATA disk, survives reboots (token/state persist), and can
# be updated in place with `nixos-rebuild switch`.
{ lib, pkgs, ... }:
{
  # disko's in-VM image builder (make-disk-image) builds the VM kernel with
  # `pkgs.aggregateModules`, whose output has no `.target`. This nixpkgs' vmTools
  # reads `kernel.target` to locate the bootable image, so the image build fails
  # with "kernel-modules has no target attribute". Re-attach it (bzImage on
  # x86_64) in the pkgs instance disko uses for image building only. Drop this
  # once disko upstream tracks the vmTools change.
  disko.imageBuilder.pkgs = pkgs.extend (
    final: prev: {
      aggregateModules =
        modules:
        (prev.aggregateModules modules).overrideAttrs (old: {
          passthru = (old.passthru or { }) // {
            target = "bzImage"; # x86_64 kernel image name (this target is x86_64-only)
          };
        });
    }
  );

  # disko's image-builder VM only auto-loads a fixed rootModules list (virtio, 9p,
  # virtiofs, +zfs when used) — btrfs is not among them, and the minimal VM has no
  # on-demand modprobe. So mounting the freshly-formatted btrfs root falls back to
  # a FUSE handler and fails ("fuseblk: Unknown parameter 'subvol'"), aborting the
  # image build. Load the btrfs module in the builder VM so it can mount our root.
  disko.imageBuilder.extraRootModules = [ "btrfs" ];

  imports = [
    # btrfs+zstd disk layout (disko). Provides fileSystems."/" and "/boot".
    ./disk-layout.nix
    # Automatic GC / store dedup / low-disk safety net. Persistent-target only:
    # the ephemeral ISO must not GC its read-only store.
    ../core/storage.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  hardware.enableRedistributableFirmware = true;

  # In-place updates: build this config's toplevel from the release tag. The
  # boot-assessment auto-rollback below covers an update that won't come up.
  dashboardAssistant.update.installable = true;
  dashboardAssistant.update.flakeAttr = "dashboard-assistant-x86-disk";

  # Grow the root partition to fill the actual disk in early boot. Paired with
  # x-systemd.growfs on / (disk-layout.nix), a small 4G image expands to use the
  # whole medium on first boot — so one image fits every board/tablet.
  boot.growPartition = true;

  # systemd-boot installed at the *removable* fallback path (\EFI\BOOT\BOOTX64.EFI).
  # ODROID H2-class firmware won't auto-boot a bootloader from a fixed SATA disk
  # via an NVRAM entry alone, but it does honour the removable fallback — the
  # same mechanism that makes USB media boot. This is the crux of the fix.
  #
  # `bootctl install` copies systemd-bootx64.efi to the removable fallback path
  # automatically, so no separate "install as removable" knob is needed. With
  # canTouchEfiVariables = false it installs with --no-variables (no NVRAM entry).
  # configurationLimit bounds how many generations get boot entries + kernels
  # copied into the small vfat ESP, so /boot can't fill up. GC (see storage.nix)
  # prunes the corresponding store paths; together they keep the disk bounded.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 3;
  boot.loader.efi.canTouchEfiVariables = false;

  # Automatic Boot Assessment (a new generation boots with a counter and is only
  # marked good once it reaches boot-complete.target, otherwise systemd-boot
  # reverts to the previous generation) is NOT enabled here: the
  # `boot.loader.systemd-boot.bootCounting` option only exists on nixpkgs-unstable
  # and was not backported to the nixos-26.05 branch this flake pins. Recovery from
  # a broken update is therefore manual, via the recovery UI. Re-enable once the
  # option lands in the stable channel (or backport the tries mechanism):
  #   boot.loader.systemd-boot.bootCounting.enable = true;

  # Gate "boot succeeded" on the dashboard actually being up: the boot is blessed
  # only once the daemon answers /healthz and the kiosk session is active. Kept in
  # place so it works the moment boot counting is re-enabled — until then it runs
  # but nothing acts on the result (no counter to bless).
  # Deliberately NOT gated on Home Assistant reachability (which can be down for
  # unrelated reasons) — a functional-but-buggy build (e.g. broken integration
  # logic) still boots healthy here and is rolled back manually from the recovery
  # UI instead.
  systemd.services.ha-boot-health = {
    description = "Gate boot success on the dashboard being healthy";
    before = [ "boot-complete.target" ];
    requiredBy = [ "boot-complete.target" ];
    after = [ "dashboard-assistant-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "ha-boot-health" ''
        # Wait up to ~3 min for the dashboard to come up healthy. Success blesses
        # this boot; persistent failure lets systemd-boot revert on later boots.
        i=0
        while [ "$i" -lt 90 ]; do
          if ${pkgs.curl}/bin/curl -fsS --max-time 3 http://localhost:8080/healthz >/dev/null 2>&1 \
             && ${pkgs.systemd}/bin/systemctl is-active --quiet greetd.service; then
            echo "dashboard healthy; blessing this boot"
            exit 0
          fi
          i=$((i + 1))
          ${pkgs.coreutils}/bin/sleep 2
        done
        echo "dashboard did not become healthy in time; not blessing this boot" >&2
        exit 1
      '';
    };
  };

  # Enough to bring up SATA/NVMe/eMMC/USB storage and HID in early boot. The eMMC
  # set (sdhci* + mmc_block + cqhci) is essential on boards that boot from soldered
  # eMMC like the ODROID H2 — without it the initrd never sees /dev/mmcblkN and the
  # by-partlabel root device times out into emergency mode.
  boot.initrd.availableKernelModules = [
    "ahci"
    "ata_piix"
    "xhci_pci"
    "ehci_pci"
    "nvme"
    "usb_storage"
    "sd_mod"
    "usbhid"
    # eMMC / SD (Intel Gemini Lake LPSS controller on the ODROID H2 is sdhci-pci
    # or sdhci-acpi; cqhci backs the eMMC command queue).
    "sdhci"
    "sdhci_pci"
    "sdhci_acpi"
    "cqhci"
    "mmc_block"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # fileSystems."/" and "/boot" are generated by disko from ./disk-layout.nix.
}
