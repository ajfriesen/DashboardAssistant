# One disk layout and bootloader on every board

Every board, the Raspberry Pis included, uses the same disko GPT layout: a FAT FIRMWARE partition typed as an EFI system partition, a btrfs root, and systemd-boot (c07d579). On the Pi, U-Boot stays only to provide UEFI. The boards then differ only in platform, name and firmware. That removes the U-Boot btrfs rebuild, a vendored mkfs shim and a second seed-import path, and it makes boot-counting rollback a config change instead of a boot-chain change.

## Considered Options

- **nixpkgs `sd-image.nix` with extlinux**: rejected because it hardcodes an MBR (`label: dos`) partition table.
- **Microsoft basic data (0700) type for the FIRMWARE partition**: kept as a fallback if rpi-eeprom#558 ever reproduces. EF00 is used because `bootctl` refuses anything else.

## Consequences

- Existing Pi installs had to reflash; updates refuse to move `/boot` (447d65c).
- The Pi 4 needs EEPROM firmware from 2020-09-14 or later (ed2a55e).
