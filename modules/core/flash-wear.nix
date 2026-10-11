# Flash endurance. Every target boots from flash — an SD card on the Pis, eMMC or
# an SSD on x86 — and on SD the write budget is the scarcest resource on the
# board. This module is about write *endurance*; modules/core/storage.nix is
# about disk *space* and modules/core/memory.nix is about RAM. Imported by every
# target via modules/core/default.nix.
#
# The failure this exists to prevent has already happened once: sendspin-player
# logged "Discovered server" on every mDNS hit — 398k lines, 99.6% of one boot's
# journal, and 2.87 GB written to the SD card in a single boot. That was fixed
# with a per-unit rate limit (modules/core/sendspin.nix:219-227); the *class* of
# problem was not. The journal was the biggest writer on the device and nothing
# bounded it: NixOS pins Storage=persistent, and an unset SystemMaxUse means
# journald will happily use 10% of the filesystem (4 GiB on the x86 SSD target).
#
# What this module does NOT need to do, because it is already done elsewhere:
# zram swap instead of swap-on-flash (memory.nix), noatime and compress=zstd on
# a btrfs root (hardware/disk-layout.nix), 1 MiB-aligned partitions and a
# first-boot growfs (same), and weekly fstrim (NixOS default, already on).
#
# --------------------------------------------------------------------------- #
# Three landmines, all load-bearing. Read before editing.
# --------------------------------------------------------------------------- #
#
# 1. DO NOT add a tmpfiles rule to make /var/log/journal NOCOW on btrfs. That has
#    been tried and reverted three times (1140f19 -> f2eb4f3 -> 0fe98d1, then
#    1ca1b48 -> e19a49f), once taking out systemd-tmpfiles-setup and half the
#    boot with it. It cannot work: systemd already ships journal-nocow.conf with
#    exactly that rule, and systemd-journal-flush.service is ordered
#    Before=systemd-tmpfiles-setup.service, so journald creates the directory and
#    its first file before any `+C` rule fires — and +C only affects files created
#    afterwards. The sync script below gets the effect a different way: with
#    Storage=volatile journald never creates anything under /var/log/journal, so
#    *we* create the directory and set +C on it before writing the first file.
#    No tmpfiles rule, no boot ordering, nothing to break.
#
# 2. Declare any new tmpfs with `systemd.mounts`, never `fileSystems`.
#    nixos/modules/virtualisation/qemu-vm.nix overrides `fileSystems` wholesale
#    with mkVMOverride, so a fileSystems-based mount is at best fragile under
#    `nix flake check` — and tests/first-boot.nix is the only automated coverage
#    this module gets. Upstream's own boot.tmp.useTmpfs uses systemd.mounts
#    (nixos/modules/system/boot/tmp.nix) for the same reason, which is why the
#    /tmp half of this module is testable at all.
#
# 3. The journald options below are spelled TWO ways on purpose. This flake
#    straddles two nixpkgs channels (flake.nix): x86 and the Pi 4 are on
#    nixos-26.05, the Pi 5 needs nixpkgs-unstable. Unstable removed
#    services.journald.{storage,rateLimitBurst,extraConfig} in favour of
#    services.journald.settings.Journal and made the old names throw; 26.05 has
#    only the old names and no `settings` at all. Writing either one alone breaks
#    exactly one target, and `nix flake check` will NOT catch it because the
#    checks are x86_64-only and therefore all-stable. Verify a change here with
#    all five configurations:
#      for h in x86-disk x86-disk-dev rpi4 rpi5 rpi5-dev; do \
#        nix eval --raw ".#nixosConfigurations.dashboard-assistant-$h.config.system.build.toplevel.drvPath"; done
#    Relatedly: a module that reads the `options` argument must put its output
#    under an explicit `config = ...`. A bare module doing so is infinite
#    recursion, which is why the dev override is an option here rather than a
#    services.journald poke in modules/dev.nix.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  # journald.conf directives, named the way systemd names them so the value is
  # identical whichever NixOS option set the channel gives us (see the branch
  # below). Overridden for dev images in modules/dev.nix.
  journalSettings = {
    Storage = "volatile";
    # Global burst, down from the stock 10000 per 30s (~333 msg/s per unit). The
    # sendspin flood fit under the stock limit comfortably, which is precisely
    # why that unit needed its own override — the global default was never going
    # to catch it. 2000 per 30s is ~66 msg/s per unit; nothing legitimate on this
    # appliance comes close, and journald still records "Suppressed N messages
    # from <unit>", so the forensic signal (this unit went mad) survives at a
    # fraction of the bytes.
    RateLimitBurst = 2000;
    # The in-RAM budget, and therefore the ceiling on what one power cut can
    # lose. Left unset this derives from /run's size, which on a 2 GB board is
    # too tight to hold a whole sync interval. A few MiB is a normal boot here.
    RuntimeMaxUse = "64M";
    # "info" drops level 7 only, so cheap. Ranked last on purpose: it would NOT
    # have prevented the sendspin incident — "Discovered server" is info, not
    # debug. modules/dev.nix raises it for the bench and the -dev images.
    MaxLevelStore = config.dashboardAssistant.flashWear.journalMaxLevelStore;
  };

  # Copy the sealed journal files out of RAM and onto flash.
  #
  # `journalctl --flush` is NOT usable here, and that is the whole reason this
  # script exists: with Storage=volatile journald refuses persistent storage
  # outright, so --flush is a no-op. The files have to be moved by hand.
  journalSync = pkgs.writeShellScript "dashboard-assistant-journal-sync" ''
    set -eu

    # Seal the live journal. Rotation renames the active system.journal to
    # system@<seq>-<realtime>.journal and opens a fresh one, so everything up to
    # now becomes a complete, self-contained, safely-copyable file.
    ${pkgs.systemd}/bin/journalctl --rotate

    mid=$(${pkgs.coreutils}/bin/cat /etc/machine-id)
    src=/run/log/journal/"$mid"
    dst=/var/log/journal/"$mid"

    [ -d "$src" ] || exit 0

    # 2755 and the systemd-journal group are what journald itself would have
    # created, so journalctl's own permission expectations are satisfied.
    ${pkgs.coreutils}/bin/install -d -m 2755 -o root -g systemd-journal "$dst"

    # NOCOW. The journal is the worst possible btrfs workload — many small
    # appends into mmap'd files — and copy-on-write turns each one into a new
    # extent plus metadata. Safe to set here (see landmine 1 in the header);
    # fails harmlessly on the vfat/tmpfs/ext4 roots a test or VM might present.
    ${pkgs.e2fsprogs}/bin/chattr +C "$dst" 2>/dev/null || true

    # Only the SEALED files: the glob requires an `@`, which the live
    # system.journal does not have. Copying the live file would mean copying a
    # journal that journald is still mmap-writing, i.e. a torn file that
    # journalctl then reports as corrupt.
    for f in "$src"/*@*.journal; do
      [ -e "$f" ] || continue
      name=$(${pkgs.coreutils}/bin/basename "$f")
      # Write to a temp name, fsync it, then rename into place. A plain `cp`
      # straight to the destination has a window where a power cut leaves a
      # truncated archive — and the log you want after a power cut is exactly
      # the one that was being written when the power went.
      ${pkgs.coreutils}/bin/cp --reflink=never "$f" "$dst/.$name.tmp"
      ${pkgs.coreutils}/bin/sync "$dst/.$name.tmp"
      ${pkgs.coreutils}/bin/mv "$dst/.$name.tmp" "$dst/$name"
      # Drop the RAM copy now that it is durable: frees the tmpfs, and keeps the
      # next sync cheap by not re-copying. journalctl merges /run/log/journal and
      # /var/log/journal transparently, so nothing becomes unreadable.
      ${pkgs.coreutils}/bin/rm -f "$f"
    done

    # Bound the archive. journald is not managing this directory, so nothing else
    # will ever prune it — without this the card fills up slowly instead of
    # wearing out quickly, which is not an improvement. 128 MiB is tens of boots
    # on this device (a normal boot is a few MiB).
    ${pkgs.systemd}/bin/journalctl -D "$dst" --vacuum-size=128M >/dev/null
  '';
in
{
  # ------------------------------------------------------------------------- #
  # The journal lives in RAM and is copied to flash on a timer and at shutdown
  # ------------------------------------------------------------------------- #
  #
  # This is armbian-ramlog's design, and it is the least mainline thing in this
  # module: no upstream NixOS module does it, so the three units below are ours
  # to maintain. The alternative considered and rejected was to keep
  # Storage=persistent and merely cap it — fully mainline, but it only bounds the
  # journal's *size*, not its write rate, so the card still takes every line.
  #
  # The cost, stated plainly because it is the thing that will eventually bite:
  # a power cut loses up to one sync interval of logs. On a wall-mounted
  # dashboard that someone unplugs, that is a real and recurring loss. The timer
  # interval below IS the data-loss window; shorten it if field reports show
  # losing logs that mattered. A user who needs crash-time logs more than card
  # life can set Storage=persistent and be back to stock.
  #
  # /run is already a tmpfs, so Storage=volatile needs no mount of its own.
  # journalctl reads BOTH /run/log/journal and /var/log/journal regardless of
  # this setting, which is why the archive goes to the standard persistent path:
  # a plain `journalctl -b -1` finds it, with no -D and no --merge.
  options.dashboardAssistant.flashWear.journalMaxLevelStore = lib.mkOption {
    type = lib.types.enum [
      "emerg"
      "alert"
      "crit"
      "err"
      "warning"
      "notice"
      "info"
      "debug"
    ];
    default = "info";
    description = ''
      Highest syslog priority still written to the journal
      ({manpage}`journald.conf(5)` `MaxLevelStore=`). Lower is less written, and
      on a flash-booted appliance that is the point. The default drops `debug`
      only; release images have no use for it and it is the chattiest level by
      far.

      Raised to `debug` by {file}`modules/dev.nix` so bench boards and `-dev`
      images keep full fidelity. An option rather than a direct
      {option}`services.journald` override because the two nixpkgs channels this
      flake straddles spell that option differently.
    '';
  };

  config = lib.mkMerge [
    # Which option set to use is decided by the channel, not by us. This flake
    # straddles two: x86 and the Pi 4 are on nixos-26.05, while the Pi 5 needs
    # nixpkgs-unstable (see flake.nix). Unstable has replaced
    # services.journald.{storage,rateLimitBurst,extraConfig} with the RFC42-style
    # services.journald.settings.Journal and made the old names throw, while
    # 26.05 has only the old names and no `settings` at all. So there is no
    # single spelling that evaluates on both, and picking the wrong one breaks
    # exactly one target — which `nix flake check` would not catch, because the
    # checks are x86_64-only and therefore all-stable.
    #
    # Branch on the option's existence rather than on a channel flag we would
    # have to thread through: when 26.05's successor grows `settings`, the else
    # branch simply stops being taken and this can be deleted.
    (
      if options.services.journald ? settings then
        { services.journald.settings.Journal = journalSettings; }
      else
        {
          services.journald.storage = journalSettings.Storage;
          services.journald.rateLimitBurst = journalSettings.RateLimitBurst;
          # The two with no typed option on 26.05. extraConfig is that module's
          # own documented escape hatch (its `example` is literally
          # "Storage=volatile"), so this is not a deviation from mainline.
          services.journald.extraConfig = ''
            RuntimeMaxUse=${journalSettings.RuntimeMaxUse}
            MaxLevelStore=${journalSettings.MaxLevelStore}
          '';
        }
    )

    {
      # ------------------------------------------------------------------------- #
      # /tmp in RAM, and Nix's build directory deliberately NOT in it
      # ------------------------------------------------------------------------- #
      #
      # This looks like a deviation and is the opposite of one: upstream systemd
      # installs tmp.mount as a tmpfs into local-fs.target.wants, so a RAM-backed
      # /tmp is what Fedora, Arch and Debian 13 ship. NixOS' useTmpfs = false is the
      # deviation, taken because Nix builds can be enormous — which is what the
      # build-dir setting below fixes outright.
      #
      # It also closes a standing hole: cleanOnBoot is false too, so today /tmp is a
      # directory on flash that is *never* cleaned, and anything leaked into it
      # outlives every reboot.
      #
      # WHY THIS IS SAFE, which is not obvious: tmpfs pages are not reclaimable
      # without swap. They do not count toward MemAvailable and cannot be dropped
      # like page cache. The only reason a RAM-backed /tmp is acceptable on a 2 GB
      # Pi 4 is that modules/core/memory.nix already provides zstd zram, so cold
      # tmpfs pages compress into it rather than pinning RAM. Without zram this
      # would be a regression, not an improvement — do not disable one without
      # revisiting the other. (And do not raise zramSwap.memoryPercent at the same
      # time as touching this: two memory variables at once makes the measurement
      # uninterpretable.)
      boot.tmp.useTmpfs = true;
      # 25%, not the 50% default: on a 2 GB Pi 4 that is 512 MiB, a ceiling a runaway
      # /tmp writer cannot exceed while still leaving the kiosk its RAM. It is a cap,
      # not a reservation. cleanOnBoot stays false on purpose — a tmpfs is empty at
      # boot by construction, so setting it would only add a pointless `D! /tmp`
      # tmpfiles rule.
      boot.tmp.tmpfsSize = "25%";

      # ...and the reason NixOS defaults useTmpfs off. Nix builds in $TMPDIR, which
      # for nix-daemon (no TMPDIR in its unit environment) is /tmp. On-device updates
      # (modules/core/update.nix) substitute almost everything from the binary cache,
      # but ONE cache miss would then try to build in RAM on a 2 GB board and die
      # with ENOSPC in the middle of a switch, on a wall-mounted device. That is the
      # one way this module could turn a wear optimisation into a brick.
      #
      # `build-dir` is Nix's own setting for exactly this (>= 2.27; this flake pins
      # 2.34.8) and is narrower than the usual folk remedy of overriding TMPDIR on
      # nix-daemon.service — it moves build directories only, not every tool's
      # scratch space. /var/tmp is on the same btrfs filesystem as /nix, so nix's
      # min-free / max-free floor (modules/core/storage.nix) still sees the same
      # free-space pool, and systemd's own tmp.conf ages /var/tmp at 30 days.
      nix.settings.build-dir = "/var/tmp";

      # Hourly, matching armbian-ramlog's default. OnBootSec gives the boot a chance
      # to settle first (and makes the first sync land while a freshly-flashed board
      # is still on the bench). Persistent=true catches up after the device has been
      # powered off through a due interval.
      systemd.timers.dashboard-assistant-journal-sync = {
        description = "Periodically copy the in-RAM journal onto flash";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15m";
          OnUnitActiveSec = "1h";
          Persistent = true;
        };
      };

      systemd.services.dashboard-assistant-journal-sync = {
        description = "Copy the in-RAM journal onto flash";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = journalSync;
        };
        # Without this the timer can fire before /var is mounted and the sync writes
        # into the root filesystem underneath the mount point.
        unitConfig.RequiresMountsFor = "/var/log";
      };

      # The clean-shutdown flush, as a separate unit rather than a fourth knob on the
      # one above: a RemainAfterExit unit cannot be re-triggered by a timer, because
      # `systemctl start` on an already-active unit is a no-op. So the timer drives
      # the oneshot above, and this one exists only to own an ExecStop.
      #
      # Default dependencies are deliberately left ON. They supply
      # Conflicts=shutdown.target and Before=shutdown.target, which is exactly what
      # makes systemd stop this unit — and therefore run ExecStop — during the
      # multi-user teardown, while /var is still mounted and journald is still alive.
      systemd.services.dashboard-assistant-journal-sync-shutdown = {
        description = "Copy the in-RAM journal onto flash before shutdown";
        wantedBy = [ "multi-user.target" ];
        before = [ "shutdown.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
          ExecStop = journalSync;
        };
        unitConfig.RequiresMountsFor = "/var/log";
      };
    }
  ];
}
