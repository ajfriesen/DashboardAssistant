# Compressed btrfs root, and keeping writes off flash

Devices run unattended from SD cards and cheap flash for years, so the OS treats flash space and flash writes as scarce.

The root is btrfs with zstd compression, which roughly halves the Nix store on an appliance nobody prunes by hand (714fa7a, 173d369). Write-heavy paths are kept in RAM (1715561, `modules/core/flash-wear.nix`):

- Swap is zram (3adcf83).
- The journal lives in RAM and is synced to flash hourly.
- `/tmp` and the browser caches are tmpfs.
- The screenshot frame lives in `/run`.

This followed an incident where a misbehaving Sendspin wrote 2.87 GB to the card in a single boot.

## Considered Options

- **A capped persistent journal**: rejected because it bounds the journal's size, not its write rate.
- **Marking the journal directory NOCOW with a tmpfiles rule**: tried twice and reverted. Once it caused a boot-killing ordering cycle (0fe98d1). Once it duplicated systemd's own `journal-nocow.conf` and could not have worked given the boot ordering (e19a49f).

## Consequences

A power cut loses up to an hour of logs.
