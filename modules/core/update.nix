# OS update: report + apply.
#
# Reporting (all targets): bakes the release version into the image so the daemon
# can tell Home Assistant which version is "installed", and points it at a
# release source to discover the "latest". The daemon exposes both as a single HA
# `update` entity through the integration API (see daemon/update.go, daemon/ha.go).
#
# Applying (installable targets only): a privileged, root-run `dashboard-assistant-update@<tag>.service` does the
# `nixos-rebuild switch --flake <ref>/<tag>#<attr>`, triggered by the daemon over
# the scoped polkit rule below when HA's Install button is pressed. The flake ref
# and hardware attr are baked in; only the target tag is a runtime instance.
# Safety net: an update that comes up unreachable is rolled back automatically
# after three attempts (./good-boot.nix, docs/adr/0009), and recovery on the
# admin page covers the rest — a device that boots fine but misbehaves, which
# automatic rollback cannot see. A preflight in the update script
# additionally refuses any release whose declared root *or* /boot filesystem
# differs from the one actually mounted — such a switch would activate cleanly
# and then fail on the next reboot, and those devices must be reflashed
# instead. Two layout changes have shipped that this guards:
#
#   * ext4 -> btrfs root on the SD images (a mismatch hangs stage 1), and
#   * the sd-image layout -> the shared disko GPT layout, which moved /boot
#     from a directory on the btrfs root to the FAT EFI system partition and
#     swapped extlinux for systemd-boot. A card on the old layout has no ESP
#     for `bootctl` to install into.
{
  config,
  lib,
  pkgs,
  version,
  ...
}:
let
  cfg = config.dashboardAssistant.update;

  updateScript = pkgs.writeShellScript "dashboard-assistant-update" ''
    set -eu
    ref=''${1:-}
    # Re-validate the tag the daemon passed (it also validates) before splicing
    # it into the flake ref — only safe git-tag characters, no shell metachars.
    case "$ref" in "" | *[!A-Za-z0-9._-]*) echo "invalid ref: $ref" >&2; exit 1 ;; esac
    target="${cfg.flakeRef}/$ref#${cfg.flakeAttr}"

    # Preflight: refuse a release whose declared layout differs from the
    # mounted one. `nixos-rebuild switch` would activate such a config without
    # complaint (the running root is never remounted), and the device would
    # then fail on the next reboot. A headless board then stays down until
    # someone pulls the card, so this check is the only thing standing between
    # a layout change and a brick.
    #
    # Both the root and /boot are compared, because both have changed shape:
    # ext4 -> btrfs roots, and /boot moving from a directory on the root
    # filesystem to its own vfat ESP. The /boot case cannot be caught by the
    # root check at all — on an old sd-image card /boot is simply part of the
    # btrfs root, so the root types match and the switch looks fine right up to
    # the point where `bootctl install` has no EFI system partition to write
    # to.
    #
    # Building the toplevel here is not wasted work: nixos-rebuild below
    # re-evaluates, but every build product comes out of the local store.
    #
    # A refusal is recorded in a marker file the daemon reads to surface the
    # reason on the HA update entity (daemon/update.go); the path matches the
    # daemon's stateDir default. Cleared up front so a stale reason from an
    # earlier attempt can't outlive this run.
    refused=/var/lib/dashboard-assistant/update-refused
    mkdir -p /var/lib/dashboard-assistant
    rm -f "$refused"

    echo "dashboard-assistant-update: building $target"
    toplevel=$(${lib.getExe' config.nix.package "nix"} build --no-link --print-out-paths --refresh \
      "${cfg.flakeRef}/$ref#nixosConfigurations.${cfg.flakeAttr}.config.system.build.toplevel")
    # Declared layout, from the release's own fstab; "-" when it declares no
    # such mount point at all (which is what an sd-image-era /boot looks like).
    declaredFs() {
      ${lib.getExe pkgs.gawk} -v mnt="$1" '$2 == mnt { print $3; found = 1 }
        END { if (!found) print "-" }' "$toplevel/etc/fstab"
    }
    # ...and the same for the running device.
    mountedFs() {
      ${lib.getExe' pkgs.util-linux "findmnt"} -n -o FSTYPE --mountpoint "$1" 2>/dev/null || echo -
    }

    targetFs=$(declaredFs /)
    runningFs=$(mountedFs /)
    # "-" means the helper found nothing. For the root that is never legitimate
    # — refuse rather than compare, or two unknowns would compare equal and
    # wave the switch through.
    if [ "$targetFs" = "-" ] || [ "$runningFs" = "-" ]; then
      msg="Cannot determine the root filesystem (release: '$targetFs', device: '$runningFs'); refusing to switch."
      echo "dashboard-assistant-update: $msg" >&2
      echo "$msg" > "$refused"
      exit 1
    fi
    if [ "$targetFs" != "$runningFs" ]; then
      msg="Release $ref needs a $targetFs root filesystem, but this device runs $runningFs. An in-place update cannot convert it — reflash the device with the $ref image instead (settings re-seed from dashboard-assistant.yaml)."
      echo "dashboard-assistant-update: $msg" >&2
      echo "$msg" > "$refused"
      exit 1
    fi

    # Same test for /boot. Reported separately rather than folded into the
    # message above, because the fix is the same but the cause reads very
    # differently: a device whose root already matches but whose /boot does not
    # is on the pre-disko sd-image layout, where /boot was a directory on the
    # btrfs root and the bootloader was extlinux.
    # Unlike the root, "-" is a legitimate answer for /boot on both sides: it
    # is what a pre-disko release declares and what a pre-disko card reports,
    # so "-" == "-" correctly permits an old-to-old update.
    targetBootFs=$(declaredFs /boot)
    runningBootFs=$(mountedFs /boot)
    if [ "$targetBootFs" != "$runningBootFs" ]; then
      msg="Release $ref expects /boot to be $targetBootFs, but on this device it is $runningBootFs. The partition layout changed (the boot files moved to an EFI system partition), which an in-place update cannot do — reflash the device with the $ref image instead (settings re-seed from dashboard-assistant.yaml)."
      echo "dashboard-assistant-update: $msg" >&2
      echo "$msg" > "$refused"
      exit 1
    fi

    echo "dashboard-assistant-update: switching to $target"
    exec ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake "$target" --refresh
  '';
in
{
  options.dashboardAssistant.update = {
    repo = lib.mkOption {
      type = lib.types.str;
      default = "ajfriesen/DashboardAssistant";
      description = ''
        owner/repo whose newest release advertises the latest available version.
        The daemon polls <apiBase>/repos/<repo>/releases/latest.
      '';
    };

    apiBase = lib.mkOption {
      type = lib.types.str;
      default = "https://api.github.com";
      example = "https://git.ajfriesen.com/api/v1";
      description = ''
        Base URL of the releases API. GitHub and Gitea share the
        /repos/<repo>/releases/latest shape, so point this at a Gitea instance to
        track self-hosted releases instead of the GitHub mirror.
      '';
    };

    checkInterval = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      example = "30m";
      description = "How often the daemon re-checks for a newer release (a Go duration).";
    };

    installable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this image can apply updates in place. Enables the privileged
        dashboard-assistant-update@ rebuild unit and the HA Install button. On for
        the persistent disk / SD targets; off by default so an image that cannot
        persist a switch never offers one.
      '';
    };

    flakeRef = lib.mkOption {
      type = lib.types.str;
      default = "github:${cfg.repo}";
      defaultText = lib.literalExpression ''"github:''${config.dashboardAssistant.update.repo}"'';
      example = "git+https://git.ajfriesen.com/ajfriesen/DashboardAssistant";
      description = ''
        Flake reference the update rebuild pulls from. The target release tag is
        appended as `<flakeRef>/<tag>`. Defaults to the GitHub mirror of `repo`.
      '';
    };

    flakeAttr = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "dashboard-x86-disk";
      description = ''
        nixosConfigurations attribute the update rebuild builds
        (`<flakeRef>/<tag>#<flakeAttr>`). Set per hardware target. Required when
        `installable` is true.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # Flake-based `nixos-rebuild --flake` needs these experimental features.
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Baked-in installed version the daemon reports to HA. World-readable
      # (0444), read at /etc/dashboard-assistant/version.
      environment.etc."dashboard-assistant/version" = {
        text = version;
        mode = "0444";
      };

      # Stamp the release onto the generation so the boot menu, `nixos-version`,
      # and `nixos-rebuild list-generations` all show which tag a generation was
      # built from — useful after an in-place update or downgrade. Appended in
      # parens after the nixpkgs label, e.g. "26.05.… (dashboard-assistant-0.1.0-rc.2)".
      # Each release tag's flake carries its own `version`, so a switch to any
      # tag self-labels correctly.
      system.nixos.tags = [ "dashboard-assistant-${version}" ];

      # Merges with the daemon service's other environment settings (daemon.nix).
      systemd.services.dashboard-assistant-daemon.environment = {
        UPDATE_REPO = cfg.repo;
        UPDATE_API_BASE = cfg.apiBase;
        UPDATE_CHECK_INTERVAL = cfg.checkInterval;
        UPDATE_INSTALLABLE = if cfg.installable then "1" else "0";
      };
    }

    (lib.mkIf cfg.installable {
      assertions = [
        {
          assertion = cfg.flakeAttr != "";
          message = "dashboardAssistant.update.flakeAttr must be set when dashboardAssistant.update.installable is true.";
        }
      ];

      # Update to release %i and switch. Instantiated per tag by the daemon
      # (dashboard-assistant-update@<tag>.service); the script re-validates %i. Runs as root; a
      # long build must not time out.
      systemd.services."dashboard-assistant-update@" = {
        description = "Update Dashboard Assistant OS to release %i and switch";
        # nixos-rebuild shells out to nix (build/eval) and git (flake fetch).
        path = [
          config.nix.package
          pkgs.git
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${updateScript} %i";
          TimeoutStartSec = "infinity";
        };
      };

      # Let the daemon start *only* the dashboard-assistant-update@ units (alongside the greetd /
      # dashboard-assistant-rollback@ grants in daemon.nix). extraConfig is concatenated, so this
      # adds a rule rather than replacing the existing one.
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (subject.user == "dashboard-assistant" &&
              action.id == "org.freedesktop.systemd1.manage-units") {
            var unit = action.lookup("unit");
            if (unit && unit.indexOf("dashboard-assistant-update@") == 0) return polkit.Result.YES;
          }
        });
      '';
    })
  ];
}
