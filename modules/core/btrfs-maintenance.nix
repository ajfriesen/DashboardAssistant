# Monthly scrub on btrfs roots, so latent corruption actually surfaces: the
# per-device error counters the daemon's filesystem-health sensor reads
# (daemon/btrfs.go) only move when bad data is read, and a scrub reads and
# verifies everything. Scrub works per filesystem, so "/" covers the x86
# layout's @nix subvolume too. No-op on legacy ext4-flashed SD cards.
{ config, lib, ... }:
{
  config = lib.mkIf (config.fileSystems."/".fsType == "btrfs") {
    services.btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
      fileSystems = [ "/" ];
    };
  };
}
