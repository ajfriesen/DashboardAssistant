---
status: accepted
---

# Every board builds from a pinned nixos-unstable

All boards build from `nixos-unstable`, pinned in `flake.lock` and bumped deliberately about once a month, not from a NixOS stable release. Stable lagged features the OS needs: systemd-boot boot counting, which automatic rollback of a bad update depends on, existed only on unstable and had to be dropped when x86 was pinned to 26.05 (a2fc528). Running some boards on stable and others on unstable also meant two configurations to maintain and test (journald options, kernel, mesa). Pinning keeps every release on a known, tested nixpkgs revision.

## Considered Options

- **Stay on stable and move to 26.11** when it branches, which also ships boot counting: this fixes the feature gap once, but the gap reopens with every feature that lands on unstable first.
- **Backport boot counting onto stable** as a local module: the same gap, plus code to carry.
- **Follow unstable unpinned**: rejected, since every rebuild could pick up upstream breakage.
