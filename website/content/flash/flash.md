# Flash the Image

If you can reach the target's storage medium (an internal SSD, a removable SD
card, or a drive in a USB adapter), the quickest path is to flash the disk image
directly.

## Requirements

Depending on your hardware you'll need a way to write to the target disk:

- An SD-card reader, **or**
- A SATA-to-USB adapter, **or**
- An NVMe/USB enclosure, **or**
- Direct access to the machine's internal disk.

You'll also need `zstd` (Linux/macOS) or a GUI flasher such as
[balenaEtcher](https://etcher.balena.io/) (Windows) to write the image.

## Download the image

There is one image per board. Grab the latest from the
[GitHub releases page](https://github.com/ajfriesen/DashboardAssistant/releases/latest)
— the download table sits at the top of the release notes and points to our
download server (GitHub can't host the multi-GB files directly). Every image is
zstd-compressed:

| Board | Image |
|---|---|
| x86_64 (mini-PC, tablet, NUC) | `dashboard-assistant-x86_64-<version>.raw.zst` |
| Raspberry Pi 4 | `dashboard-assistant-rpi4-<version>.raw.zst` |
| Raspberry Pi 5 | `dashboard-assistant-rpi5-<version>.raw.zst` |

All three boards use the same image format and the same flashing steps — there
is nothing Pi-specific to do any more.

x86_64 targets need to boot **UEFI** — see the
[x86_64 requirements](../hardware-support/x86.md).

!!! tip "Verify the download"
    The image is several GB even compressed. If a flash fails midway, re-download
    and check the file size against the release page before retrying.

## Flash the image

The procedure is the same for every board — an x86_64 image goes to the SSD or
internal disk, a Raspberry Pi image goes to the SD card (usually
`/dev/mmcblkX` in a built-in slot, `/dev/sdX` in a USB reader).

!!! danger "Double-check the target device"
    `dd` writes with no confirmation. Flashing the wrong disk will **erase it**.
    List your disks first and confirm the device node before running the command.

=== "Linux"

    Identify the target disk:

    ```bash
    lsblk -o NAME,SIZE,MODEL,TRAN
    ```

    Decompress and write it in one pipe (replace `/dev/sdX` with your device):

    ```bash
    zstd -dc dashboard-assistant-*.zst \
      | sudo dd of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress
    sync
    ```

=== "macOS"

    Identify the target disk:

    ```bash
    diskutil list
    ```

    Unmount it (don't eject), then decompress and write to the *raw* device node
    (`/dev/rdiskN` is faster than `/dev/diskN`):

    ```bash
    diskutil unmountDisk /dev/diskN
    zstd -dc dashboard-assistant-*.zst \
      | sudo dd of=/dev/rdiskN bs=4m
    ```

    `zstd` is available via [Homebrew](https://brew.sh/): `brew install zstd`.

=== "Windows / GUI"

    1. Download [balenaEtcher](https://etcher.balena.io/).
    2. Decompress the `.zst` file with [7-Zip](https://www.7-zip.org/) (or
       `zstd -d`) to get the raw `.raw` / `.img` image.
    3. In Etcher, choose **Flash from file**, select the image, pick the
       target drive, and flash.

Once the flash finishes, move the disk into the target machine (or leave it in
place) and boot it. On Ethernet the device gets online by itself. For Wi-Fi, or to
configure a device before it ever boots, write a [seed file](seed.md) — that is
also how you set up several tablets or do a headless install.

On a freshly flashed card or disk, the small `ESP` partition your file manager
shows carries a `README.txt` and an example seed file. That is where the seed
file goes, and the README on the card repeats the instructions.

## Raspberry Pi 4: check your bootloader EEPROM

Pi 5 boards need nothing special. A **Raspberry Pi 4** does: these images use a
GPT partition table, which the Pi 4's bootloader only understands from the
September 2020 EEPROM onwards. Any board bought since late 2020, or that has
ever run a recent Raspberry Pi OS, is already fine.

If a Pi 4 shows no sign of life after flashing, check its bootloader from a
Raspberry Pi OS card:

```bash
vcgencmd bootloader_version
```

and update it if the date is older than `2020/09/14`:

```bash
sudo rpi-eeprom-update -a && sudo reboot
```

This has to be done from a Raspberry Pi OS card, not from ours: the EEPROM
recovery file is read by a part of the chip that predates GPT support entirely,
so a Dashboard Assistant card cannot repair a board that cannot boot it.
