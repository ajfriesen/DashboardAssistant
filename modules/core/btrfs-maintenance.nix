# btrfs upkeep for the root filesystem. No-op on legacy ext4-flashed SD cards.
#
# Scrub: monthly, so latent corruption actually surfaces. The per-device error
# counters the daemon's filesystem-health sensor reads (daemon/btrfs.go) only
# move when bad data is read, and a scrub reads and verifies everything. Scrub
# works per filesystem, so "/" covers the x86 layout's @nix subvolume too.
#
# NOCOW journals: the systemd journal is the worst possible btrfs workload —
# small appends to a large file, forever. Under copy-on-write every append
# allocates a new extent, which fragments the journal into tens of thousands of
# extents, makes journalctl crawl, and multiplies writes on a card that only has
# so many. +C on the directory makes files *created inside it* nodatacow, so it
# has to be set before journald writes its first file, which is what the tmpfiles
# rules below do: systemd-tmpfiles-setup runs long before journal flush.
{ config, lib, ... }:
{
  config = lib.mkIf (config.fileSystems."/".fsType == "btrfs") {
    services.btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
      fileSystems = [ "/" ];
    };

    # d creates the directory with journald's ownership if it is not there yet;
    # h applies +C to it. Order matters, and tmpfiles applies rules in the order
    # given within a single fragment. +C only affects newly created files, so on
    # a device whose journal already exists this takes effect for future files
    # (rotation) rather than retroactively.
    systemd.tmpfiles.rules = [
      "d /var/log/journal 2755 root systemd-journal - -"
      "h /var/log/journal - - - - +C"
    ];
  };
}
