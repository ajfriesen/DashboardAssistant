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
| Raspberry Pi 4 | `dashboard-assistant-rpi4-<version>.img.zst` |
| Raspberry Pi 5 | `dashboard-assistant-rpi5-<version>.img.zst` |

The newest release is also always available directly at
`https://download.dashboardassistant.org/release/<board>/latest.raw.zst`
(x86_64) or `…/release/<board>/latest.img.zst` (Pi), with `x86_64`, `rpi4` or
`rpi5` as the board.

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
place) and boot it. On Ethernet the device gets online by itself; on Wi-Fi it
starts the on-screen [Wi-Fi setup](wifi.md). To configure a device before it
ever boots — for several tablets, or a headless install — use a
[seed file](seed.md) instead.
