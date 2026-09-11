# Monthly scrub on btrfs roots, so latent corruption actually surfaces: the
# per-device error counters the daemon's filesystem-health sensor reads
# (daemon/btrfs.go) only move when bad data is read, and a scrub reads and
# verifies everything. Scrub works per filesystem, so "/" covers the x86
# layout's @nix subvolume too. No-op on the live ISO (squashfs+tmpfs overlay
# root) and on legacy ext4-flashed SD cards.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.fileSystems."/".fsType == "btrfs") {
    services.btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
      fileSystems = [ "/" ];
    };

    # Journald's first flush creates /var/log/journal before tmpfiles has run
    # systemd's own journal-nocow.conf (+C on that dir), so a fresh image's
    # first boot creates the dir — and its first journal file — copy-on-write,
    # and journald warns about it on the console.
    #
    # DO NOT fix this with tmpfiles + an After=systemd-tmpfiles-setup.service
    # on the flush: upstream systemd-journal-flush.service ships
    # Before=systemd-tmpfiles-setup.service (so the nocow/ACL rules can act on
    # the dir the flush creates), and the contradiction is an ordering cycle.
    # systemd breaks cycles by deleting jobs — a previous attempt took out
    # systemd-tmpfiles-setup itself and with it half the boot (empty /var/log,
    # root-owned state dirs, sshd/avahi never started). The only safe slot is
    # a oneshot ordered before the flush, so the dir already exists NOCOW when
    # journald first touches it. NOCOW files skip btrfs checksums; journald
    # has its own integrity checking, and the monthly scrub covers the rest.
    systemd.services.journal-nocow-dir = {
      description = "Create /var/log/journal NOCOW before journald's flush";
      wantedBy = [ "systemd-journal-flush.service" ];
      before = [ "systemd-journal-flush.service" ];
      after = [ "systemd-remount-fs.service" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /var/log/journal
        ${pkgs.e2fsprogs}/bin/chattr +C /var/log/journal || true
      '';
    };

    # Bound the journal so it can't crowd the card; 64M of appliance logs is
    # weeks of history, and update/debug workflows only ever need the recent
    # boots.
    services.journald.extraConfig = "SystemMaxUse=64M";
  };
}
