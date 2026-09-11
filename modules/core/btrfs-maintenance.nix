# Monthly scrub on btrfs roots, so latent corruption actually surfaces: the
# per-device error counters the daemon's filesystem-health sensor reads
# (daemon/btrfs.go) only move when bad data is read, and a scrub reads and
# verifies everything. Scrub works per filesystem, so "/" covers the x86
# layout's @nix subvolume too. No-op on the live ISO (squashfs+tmpfs overlay
# root) and on legacy ext4-flashed SD cards.
{ config, lib, ... }:
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
    # and journald warns about it on the console. Create the dir up front and
    # hold the flush until tmpfiles has stamped it, so every journal file is
    # NOCOW from the start. NOCOW files skip btrfs checksums; journald has its
    # own integrity checking, and the monthly scrub still covers the rest.
    systemd.tmpfiles.rules = [ "d /var/log/journal 2755 root systemd-journal -" ];
    systemd.services.systemd-journal-flush.after = [ "systemd-tmpfiles-setup.service" ];

    # Bound the journal so it can't crowd the card; 64M of appliance logs is
    # weeks of history, and update/debug workflows only ever need the recent
    # boots.
    services.journald.extraConfig = "SystemMaxUse=64M";
  };
}
