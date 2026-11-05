---
status: accepted
---

# A swap file on its own subvolume backs zram

Swap stays compressed RAM first: zram at priority 100. Behind it sits a 1 GiB swap file on a top-level `@swap` subvolume, at priority 10, so the kernel writes swap to flash only once zram is full. This amends [0004](0004-compressed-btrfs-root-and-keeping-writes-off-flash.md), which kept swap in RAM only.

A 2 GB board is where it matters. Limited to 2 GB, the bench Pi 5 held the kiosk with about 250 MB of browser memory in zram and no kill, but Chromium kept growing as it moved between pages. When zram fills, the only way out without a swap file is an OOM kill of the browser. A few writes to flash under real memory pressure are a better trade than a restarting screen, and the writes happen only then.

The file is created on first boot, not in the image: disko's own swap-file support would allocate it at build time and put a gigabyte of zeros into every image. NixOS creates it with `btrfs filesystem mkswapfile`, which makes it NOCOW and so uncompressed, as btrfs requires. It has its own subvolume because btrfs refuses to swap to a file in a subvolume that is snapshotted, and keeping it out of `@` keeps it out of any snapshot of the root.

## Consequences

- systemd-oomd now runs on the Pi. The Raspberry Pi kernel ships pressure tracking switched off, so oomd's unit was skipped at every boot; `psi=1` turns it on.
- The daemon reports zram use, swap file use, swap traffic and OOM kills, and the integration shows them as diagnostic sensors. Whether a board ever writes swap to flash is read off Home Assistant's history, not guessed.
- The reclaim tuning in `modules/core/memory.nix` was chosen for zram alone. `vm.page-cluster = 0` also turns off readahead from the swap file, and `vm.swappiness = 180` favours swapping over dropping page cache once zram is full. Both are right while the file is a last resort; if the sensors show the file in regular use, they are the first thing to revisit.
- The image's root has under a gigabyte free, so the swap file is created only after the root has grown to fill the medium.
