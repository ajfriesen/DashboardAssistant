# Import dashboard config (HA URL, token, Wi-Fi) from a YAML file, so a device
# can be provisioned without the on-screen wizard — handy for testing and field
# deploys. Two triggers, both feeding the daemon's loopback /api/import:
#
#   1. USB hot-insert: udev fires a per-device service that mounts an inserted
#      USB filesystem read-only and, if it holds dashboard-assistant.yaml, imports it.
#   2. Boot medium: the flashed card/disk carries a FAT partition editable on
#      any computer, so dropping dashboard-assistant.yaml on it provisions a
#      freshly flashed image on first boot — and editing it later re-provisions
#      the device in place. That partition is `/boot` (the ESP) on every target
#      now — x86 and both Raspberry Pis — which is what lets this module have a
#      single code path; see bootImport below.
#
# YAML schema (all keys optional):
#   ha_url: "https://homeassistant.local:8123"
#   token: "eyJhbGci..."          # long-lived access token (stored for injection)
#   wifi: { ssid: "Net", psk: "secret" }
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dashboard.configImport;

  stateDir = "/var/lib/dashboard-assistant";

  # sha256 of the last seed file the boot importer applied successfully. This is
  # what makes re-provisioning work: see bootImport. Written here, consumed via
  # the read-only option below — see its description for who else depends on it.
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

    Everything else on this partition is how the device starts up: the
    bootloader, the Linux kernels, and on a Raspberry Pi the firmware files as
    well (config.txt, u-boot.bin, *.dtb, overlays/). Deleting any of it makes
    the device unbootable.

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

  # The seed file lives on /boot, the FAT EFI system partition, which is
  # mounted on every target. It is the one partition a user can write to from
  # Windows or macOS after flashing, which is the whole point of the feature.
  #
  # This used to need a second code path: the sd-image targets put /boot on the
  # btrfs root, where no desktop OS can reach it, and exposed a separate
  # unmounted FAT `FIRMWARE` partition instead — so the importer had to find it
  # by label, mount it read-only and unmount it again. The Pi images are built
  # by disko from the same layout as x86 now, so /boot *is* that partition and
  # the fallback is gone along with the option that named it.
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

    [ -f /boot/${seedFileName} ] || exit 0
    tryImport /boot/${seedFileName} /boot
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

    seedHashFile = lib.mkOption {
      type = lib.types.str;
      default = seedHashFile;
      readOnly = true;
      internal = true;
      description = ''
        Where the boot importer records the hash of the last seed file it
        applied. Single source of truth for that path: the importer writes it,
        and modules/core/daemon.nix passes it to the Go daemon (which deletes
        it on factory reset, so a reset device re-imports the card it sits on)
        via `DASHBOARD_ASSISTANT_SEED_HASH_FILE`. The bench helper
        labgrid/seed.py deletes the same path to re-arm imports — update it if
        this ever moves; nothing generates that file from here.
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

    # Make /boot a drop zone that explains itself. Staged through
    # systemd-boot's extraFiles rather than a per-target image hook, which is
    # what makes one definition cover every target: the bootloader installer
    # runs both inside disko's image build (nixos-install ends in
    # `switch-to-configuration boot`) and on every later system switch, so the
    # files land on a freshly flashed card and are restored if someone deletes
    # them and then updates.
    #
    # This is also the x86 image's first copy of these files. Under the
    # sd-image builder the README and the example only ever reached the Pi
    # targets, because they were staged via sdImage.populateFirmwareCommands —
    # which the x86 image has no equivalent of — while docs/flash/seed.md told
    # x86 users to write a seed file onto the ESP all the same.
    (lib.mkIf cfg.enable {
      boot.loader.systemd-boot.extraFiles = {
        "README.txt" = dropzoneReadme;
        "${seedFileName}.example" = dropzoneExample;
      };
    })
  ];
}
