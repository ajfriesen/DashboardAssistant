# Import dashboard config (HA URL, token, Wi-Fi) from a YAML file, so a device
# can be provisioned without the on-screen wizard — handy for testing and field
# deploys. Two triggers, both feeding the daemon's loopback /api/import:
#
#   1. USB hot-insert: udev fires a per-device service that mounts an inserted
#      USB filesystem read-only and, if it holds dashboard-assistant.yaml, imports it.
#   2. Boot medium: the flashed card/disk carries a small FAT partition editable
#      on any computer, so dropping dashboard-assistant.yaml on it provisions a
#      freshly flashed image on first boot — and editing it later re-provisions
#      the device in place. Which partition that is differs per target, and this
#      module also stages a README onto it; see bootImport and the sdImage block
#      below.
#
# YAML schema (all keys optional):
#   ha_url: "https://homeassistant.local:8123"
#   token: "eyJhbGci..."          # long-lived access token (stored for injection)
#   wifi: { ssid: "Net", psk: "secret" }
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.dashboard.configImport;

  stateDir = "/var/lib/dashboard-assistant";

  # sha256 of the last seed file the boot importer applied successfully. This is
  # what makes re-provisioning work: see bootImport.
  seedHashFile = "${stateDir}/seed-hash";

  seedFileName = "dashboard-assistant.yaml";

  # Same URL daemon/main.go puts in the splash QR code, so the README on the
  # card, the screen and the docs all point at one page.
  seedDocsURL = "https://dashboardassistant.org/flash/seed/";

  # curl the given YAML file to the daemon. Retries so it works even if the
  # importer races the daemon's startup.
  postToDaemon = file: ''
    ${pkgs.curl}/bin/curl -fsS \
      --retry 10 --retry-connrefused --retry-delay 1 --max-time 30 \
      -H 'Content-Type: application/yaml' \
      --data-binary @${file} http://localhost:8080/api/import
  '';

  usbImport = pkgs.writeShellScript "dashboard-assistant-usb-import" ''
    set -eu
    dev="$1"
    mnt="$(${pkgs.coreutils}/bin/mktemp -d)"
    trap '${pkgs.util-linux}/bin/umount "$mnt" 2>/dev/null || true; ${pkgs.coreutils}/bin/rmdir "$mnt" 2>/dev/null || true' EXIT
    # Read-only mount; bail quietly if it isn't a mountable filesystem.
    ${pkgs.util-linux}/bin/mount -o ro "$dev" "$mnt" 2>/dev/null || exit 0
    [ -f "$mnt/${seedFileName}" ] || exit 0
    echo "importing dashboard config from $dev"
    ${postToDaemon "\"$mnt/${seedFileName}\""}
  '';

  # Staged onto the FAT partition at image build time so the drop zone explains
  # itself to whoever opens the card. Nothing reads these back.
  dropzoneReadme = pkgs.writeText "dashboard-assistant-firmware-README.txt" ''
    Dashboard Assistant - seed file drop zone
    =========================================

    This partition is the one place you can configure this device from another
    computer, including before it has ever booted.

      1. Copy dashboard-assistant.yaml.example to ${seedFileName}
         (same folder, right next to this README).
      2. Open it in a plain text editor, remove the leading # from the lines you
         need, and fill them in.
      3. Eject the card and boot the device.

    The device re-reads this file whenever its contents change, not only on the
    first boot:

      * edit it and reboot  -> the new values are applied
      * leave it alone      -> the device keeps whatever it has, including
                               changes you made on the device itself or from
                               Home Assistant
      * delete it           -> same thing; nothing is applied from here again

    One caveat when you do edit it: the whole file is applied, not just the line
    you changed. That matters for the pages: block, which replaces the device's
    page list outright - so pages you added or reordered in Home Assistant are
    replaced by whatever the file says. Delete the pages: block to manage pages
    from Home Assistant instead.

    Anyone who can pull this card can read your Wi-Fi password and token in
    plain text. Delete ${seedFileName} once setup is done if that matters
    where this device lives.

    If the device does not pick the file up, the most likely cause is YAML
    indentation. The device logs what it did, and any parse error, under

      journalctl -u dashboard-assistant-boot-import

    Everything else on this partition (config.txt, u-boot.bin, *.dtb,
    overlays/) is the Raspberry Pi boot chain. Deleting any of it makes the
    device unbootable.

    Full documentation: ${seedDocsURL}
  '';

  # Deliberately NOT named ${seedFileName}: shipping this file must not be able
  # to provision anything. Every key is commented out for the same reason — a
  # user who renames it without editing it gets a clean no-op rather than a
  # device silently pointing at homeassistant.local.
  dropzoneExample = pkgs.writeText "dashboard-assistant.yaml.example" ''
    # Dashboard Assistant seed file.
    #
    # Rename this file to exactly   ${seedFileName}   (drop the .example) and
    # this device applies it on the next boot, and again whenever you change it.
    # See README.txt next to this file, or ${seedDocsURL}
    #
    # Every key is optional. Delete the ones you do not need.

    # Home Assistant base URL the dashboard should open.
    #ha_url: "http://homeassistant.local:8123"

    # Wi-Fi credentials. Delete this whole block on a wired device.
    #wifi:
    #  ssid: "MyNetwork"
    #  psk: "supersecret"

    # Long-lived Home Assistant access token for kiosk auto-login. You normally
    # do NOT need this: the Dashboard Assistant integration provisions a login
    # for the device by itself.
    #token: "eyJhbGciOi..."

    # Device API token, the credential Home Assistant uses to talk to this
    # device. Leave it out and the device generates its own, which Home
    # Assistant picks up when it pairs.
    #api_token: "a-long-random-string"

    # Dashboard pages. WARNING: this replaces the device's page list every time
    # this file changes, so pages added or reordered in Home Assistant are lost
    # on the next boot. Delete this block to manage pages from Home Assistant.
    #pages:
    #  - name: "Home"
    #    url: "http://homeassistant.local:8123/lovelace/0"
    #  - name: "Kitchen"
    #    url: "http://homeassistant.local:8123/lovelace/kitchen"
  '';

  # Look for the seed file on whichever partition the user could actually have
  # written it to, which is not the same place on every target:
  #
  #   x86 disk image  /boot IS the ESP (vfat), already mounted. Unchanged.
  #   rpi4 / rpi5     /boot is a directory on the btrfs root — a user cannot write
  #                   there from Windows or macOS at all. The partition they DO
  #                   see after flashing is the FAT one, labelled by
  #                   dashboard.configImport.firmwarePartitionLabel, which the
  #                   sd-image declares `noauto`, so it is never mounted.
  #
  # Hence the fallback: mount that partition read-only, just long enough to read
  # the file. Read-only and momentary on purpose — it holds config.txt,
  # u-boot.bin and the DTBs, i.e. the whole boot chain, and this is a device
  # people switch off at the wall. Keeping a vfat mounted read-write for the life
  # of a kiosk is how an SD card ends up with an unbootable firmware partition and
  # no console to explain why. Same shape as usbImport above.
  #
  # Re-import is gated on the file's CONTENT HASH, not on a provisioned marker.
  # That is what lets a user re-provision a device in place by editing the card
  # and rebooting, while a normal boot stays a no-op: no POST, no writes, and no
  # kiosk restart. Hashing the contents rather than stat'ing the mtime is not
  # fussiness — FAT timestamps are 2-second granularity with no timezone, and
  # Windows and macOS stamp them differently, so a byte-identical re-copy of the
  # same file would re-trigger an import.
  bootImport = pkgs.writeShellScript "dashboard-assistant-boot-import" ''
    set -eu

    seen=${seedHashFile}

    # Import $1 unless it is byte-identical to the last file imported
    # successfully. $2 names the source, for the log line only.
    tryImport() {
      new="$(${pkgs.coreutils}/bin/sha256sum < "$1" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      if [ -r "$seen" ] && [ "$(${pkgs.coreutils}/bin/cat "$seen")" = "$new" ]; then
        echo "seed file on $2 is unchanged since the last import, skipping"
        exit 0
      fi
      echo "importing dashboard config from $2"
      ${postToDaemon "\"$1\""}
      # Recorded only after the POST succeeded: `set -eu` aborts above on a
      # non-2xx, so a malformed file keeps being retried — and keeps failing
      # visibly — instead of being swallowed once and forgotten. That failed
      # unit is the only feedback channel a headless device has.
      ${pkgs.coreutils}/bin/printf '%s\n' "$new" > "$seen"
      exit 0
    }

    # Already-mounted boot partition (the x86 ESP).
    if [ -f /boot/${seedFileName} ]; then
      tryImport /boot/${seedFileName} /boot
    fi

    # ...otherwise the sd-image firmware partition, which is not mounted.
    fw=${lib.escapeShellArg "/dev/disk/by-label/${cfg.firmwarePartitionLabel}"}
    [ -e "$fw" ] || exit 0
    mnt="$(${pkgs.coreutils}/bin/mktemp -d)"
    trap '${pkgs.util-linux}/bin/umount "$mnt" 2>/dev/null || true; ${pkgs.coreutils}/bin/rmdir "$mnt" 2>/dev/null || true' EXIT
    ${pkgs.util-linux}/bin/mount -o ro "$fw" "$mnt" 2>/dev/null || exit 0
    [ -f "$mnt/${seedFileName}" ] || exit 0
    tryImport "$mnt/${seedFileName}" "$fw"
  '';
in
{
  options.dashboard.configImport = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Import dashboard config (HA URL, token, Wi-Fi) from a dashboard-assistant.yaml
        on an inserted USB stick, and from the flashed boot medium.

        On by default: seed-file provisioning is the documented headless path (a
        fleet operator drops one YAML and every panel comes up identically), so a
        release image has to carry it. It used to be switched on only by
        modules/local.nix, which meant the feature shipped by accident and was
        absent from the VM tests.

        Security note: any USB carrying that file will be applied (this trusts
        physical access). Turn this off where the ports aren't trusted.
      '';
    };

    firmwarePartitionLabel = lib.mkOption {
      type = lib.types.str;
      default = "FIRMWARE";
      description = ''
        Filesystem label of the FAT partition the boot importer mounts when
        `/boot` itself carries no seed file.

        That partition is the drop zone a user can actually write to after
        flashing an sd-image: on the Pi targets `/boot` is a directory on the
        btrfs root, and the only partition Windows and macOS can see is the FAT
        one. The sd-image targets set this from
        {option}`sdImage.firmwarePartitionName`, so renaming the partition
        cannot silently break seeding again — which is exactly what happened
        once (see labgrid/README.md).

        The default is harmless on the x86 disk image, where `/boot` *is* the
        ESP and nothing carries this label: the fallback is skipped because
        /dev/disk/by-label/&lt;label&gt; does not exist. Kept as a plain default
        rather than null for that reason — the failure mode this feature has
        actually shipped is "the importer did not look at the partition", and a
        default that always looks cannot reproduce it.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # USB hot-insert: start the per-device importer for each newly added USB
      # filesystem partition (internal SATA/NVMe disks are not ID_BUS==usb).
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", ENV{ID_FS_USAGE}=="filesystem", TAG+="systemd", ENV{SYSTEMD_WANTS}+="dashboard-assistant-usb-import@%k.service"
      '';

      systemd.services."dashboard-assistant-usb-import@" = {
        description = "Import dashboard config from USB /dev/%I";
        after = [ "dashboard-assistant-daemon.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${usbImport} /dev/%I";
        };
      };

      # Boot-medium drop-in. Runs on every boot and lets the script decide,
      # which is deliberate twice over:
      #
      # The seed file itself is NOT a ConditionPathExists. Conditions cannot see
      # inside an unmounted filesystem, and on the sd-images the file lives on a
      # partition this unit has to mount for itself — gating on the path is
      # exactly what made seeding a Pi fail silently.
      #
      # Nor is there a condition on the provisioned marker any more. That turned
      # seeding into a one-shot: editing the YAML on the card did nothing on an
      # already-provisioned device, with nothing logged, which is the same
      # failure shape in a different costume. The script's content-hash check
      # replaces it — see bootImport — and costs one oneshot per boot that
      # usually exits in milliseconds.
      systemd.services.dashboard-assistant-boot-import = {
        description = "Import dashboard config from the boot medium";
        wantedBy = [ "multi-user.target" ];
        after = [ "dashboard-assistant-daemon.service" ];

        # Finish before the session starts. On a boot that does import something
        # (the first one, or the one after an edit) the daemon restarts the kiosk
        # — and without this that restart lands on a session mid-autologin, so
        # the owner watches the screen tear down and come back. Ordering ahead of
        # greetd turns it into a no-op: RestartUnit on a unit that has not
        # started yet simply starts it, and systemd merges that job with the one
        # graphical.target already has queued.
        #
        # Ordering only — nothing here can stop greetd. If this unit fails or is
        # skipped, greetd starts the moment it terminates. No cycle: greetd is
        # itself `after` the daemon (kiosk.nix) and its own After= list
        # (systemd-user-sessions, getty@tty1) has no edge back toward
        # multi-user.target.
        before = [ "greetd.service" ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${bootImport}";
          # Bound the delay the Before= above can impose on first paint. curl
          # retries for ~30 s if the daemon is wedged; past that, let the session
          # start rather than hold a black screen.
          TimeoutStartSec = 45;
        };
      };
    })

    # Make the FAT partition a drop zone that explains itself, and keep the label
    # the importer searches identical to the one the image is built with.
    #
    # lib.optionalAttrs, not lib.mkIf: on the x86 disk image there is no sdImage
    # option at all, so these must be absent from the *definition*, not merely
    # disabled. Exactly the pattern nixos-hardware's
    # raspberry-pi/common/firmware.nix uses, for the same reason.
    (lib.optionalAttrs (options ? sdImage) (
      lib.mkIf cfg.enable {
        # One source of truth. Renaming the partition used to be able to break
        # seeding silently (labgrid/README.md, "What this bench found").
        dashboard.configImport.firmwarePartitionLabel = config.sdImage.firmwarePartitionName;

        # 30 MiB (the upstream default) leaves 4.49 MiB free on the built Pi 5
        # image: 48 files, 25,056,606 bytes used. That is less than one
        # raspberrypifw bump — a single start*.elf is 0.85-4.9 MiB today — so one
        # more board's blob set would turn a routine input bump into a
        # release-blocking build failure. And we now invite users to write here.
        # 64 MiB leaves ~38 MiB. The extra is truncate'd zeros inside the FAT free
        # space, which zstd flattens, so the shipped .img.zst does not grow; only
        # the uncompressed .img does, by 34 MiB on 3.87 GiB.
        sdImage.firmwareSize = lib.mkDefault 64;

        # Append to nixos-hardware's U-Boot/firmware staging rather than replacing
        # it. mkForce matches its priority so our text is not discarded; mkAfter
        # orders us last among the priority-50 definitions, which types.lines then
        # concatenates. A *plain* mkAfter is dropped by filterOverrides before the
        # merge ever happens — that is the trap here, and the eval check in
        # .github/workflows is what guards it.
        #
        # Dropping files into ./firmware rather than into the finished image means
        # sd-image.nix's own determinism and verification cover them: it next runs
        # `find firmware -exec touch --date=2000-01-01 {} +`, mcopy's everything in
        # sorted order, and gates on `fsck.vfat -vn`. postBuildCommands runs after
        # all three and would have meant re-implementing them.
        sdImage.populateFirmwareCommands = lib.mkForce (
          lib.mkAfter ''
            # A guard, not decoration. This block only lands because nixos-hardware
            # also uses mkForce here. If it ever drops to plain priority, ours wins
            # outright and the firmware partition ships with nothing but these two
            # files: no config.txt, no u-boot.bin, no DTBs — a board that flashes the
            # green LED seven times and says nothing about why. Fail the build.
            for f in config.txt u-boot.bin; do
              if [ ! -f "./firmware/$f" ]; then
                echo "sd-image: ./firmware/$f is missing after populateFirmwareCommands." >&2
                echo "  modules/core/configimport.nix appends with mkForce (mkAfter ...); check that" >&2
                echo "  nixos-hardware raspberry-pi/common/firmware.nix still sets it with lib.mkForce." >&2
                exit 1
              fi
            done

            # install, not cp: store paths are 0444, and 0644 makes the determinism
            # touch that sd-image.nix runs next unconditional.
            install -m 0644 ${dropzoneReadme} ./firmware/README.txt
            install -m 0644 ${dropzoneExample} ./firmware/${seedFileName}.example
          ''
        );
      }
    ))
  ];
}
