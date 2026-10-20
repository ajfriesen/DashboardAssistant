---
status: accepted
---

# Updates switch generations and roll back automatically

A device updates by building a release tag into a new NixOS generation and switching to it (`modules/core/update.nix`), not by writing a second root partition as A/B appliance updaters (RAUC, Mender, systemd-sysupdate) do. Generations already give A/B semantics: the previous system stays bootable and shares the Nix store with the new one, so a second root partition would only waste flash.

The safety net is automatic rollback through systemd-boot boot counting. A new generation gets 3 attempts to reach a good boot, meaning the device is reachable on the local network so recovery is possible. Otherwise the device falls back to the previous generation. A blank screen or an unreachable Home Assistant does not count as a failed boot: they are not the update's fault, and rolling back for them would loop. A device remembers a release it rolled back from, skips it until a newer one ships, and reports the rollback to Home Assistant through the integration.

## Consequences

- A freshly flashed device has a single generation and nothing to roll back to. If it never reaches a good boot, it keeps booting it and the user reflashes. Automatic rollback protects updates, not flashing.
- Boot counting needs systemd-boot on every board ([0003](0003-one-disk-layout-and-bootloader-on-every-board.md)) and a nixpkgs that ships it ([0008](0008-every-board-builds-from-pinned-nixos-unstable.md)).
