---
icon: lucide/rocket
---

# Getting Started

Going from a spare mini-PC or Raspberry Pi to a working Home Assistant dashboard
takes a download and four steps. Follow them in order.

## Download the image { #download }

The current release is **1.0.0**
([release notes](https://github.com/ajfriesen/DashboardAssistant/releases/tag/v1.0.0)).
There is one image per board:

| Board | Image |
|---|---|
| x86_64 (mini-PC, NUC) | [`dashboard-assistant-x86_64-1.0.0.raw.zst`](https://download.dashboardassistant.org/release/x86_64/dashboard-assistant-x86_64-1.0.0.raw.zst) |
| Raspberry Pi 4 | [`dashboard-assistant-rpi4-1.0.0.raw.zst`](https://download.dashboardassistant.org/release/rpi4/dashboard-assistant-rpi4-1.0.0.raw.zst) |
| Raspberry Pi 5 | [`dashboard-assistant-rpi5-1.0.0.raw.zst`](https://download.dashboardassistant.org/release/rpi5/dashboard-assistant-rpi5-1.0.0.raw.zst) |

Every image is zstd-compressed and several GB even so. All three boards use the
same image format and the same flashing steps. x86_64 targets need to boot
**UEFI**; see the [x86_64 requirements](hardware-support/x86.md).

!!! tip "Verify the download"
    If a flash fails midway, download the image again and check its size before
    retrying.

## 1. Flash the image { #flash }

Write the image to the target's disk: an x86_64 image goes to the SSD or
internal disk, a Raspberry Pi image goes to the SD card. To reach the disk you
need an SD-card reader, a SATA-to-USB adapter, an NVMe/USB enclosure, or direct
access to the machine's internal disk.

!!! danger "Double-check the target device"
    `dd` writes with no confirmation. Flashing the wrong disk will **erase it**.
    List your disks first and confirm the device node before running the command.

=== "Linux"

    Identify the target disk. An SD card is usually `/dev/mmcblkX` in a
    built-in slot and `/dev/sdX` in a USB reader:

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
       `zstd -d`) to get the raw `.raw` image.
    3. In Etcher, choose **Flash from file**, select the image, pick the
       target drive, and flash.

On Ethernet, move the disk into the target machine (or leave it in place) and
boot it. For Wi-Fi, write a seed file first.

??? info "Raspberry Pi 4: check your bootloader EEPROM"

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

## 2. Get it on your network { #seed-file }

On Ethernet there is nothing to do; skip to [step 3](#integration).

For Wi-Fi you need a **seed file**: the display has no way to ask for Wi-Fi
credentials on screen, so the seed file is how they reach the device. It carries
Wi-Fi and nothing else. Once the device is on your network, Home Assistant
discovers it, and adding it there sets up the rest: its Home Assistant URL, the
login, the dashboard and the pages.

Create a file named exactly `dashboard-assistant.yaml`:

```yaml
wifi:
  ssid: "MyNetwork"
  psk: "supersecret"
```

| Key         | Description                       |
| ----------- | --------------------------------- |
| `wifi.ssid` | Wi-Fi network name to join.       |
| `wifi.psk`  | Wi-Fi pre-shared key (password).  |

Any other key is ignored.

After flashing, the card or disk carries a small FAT partition that any
computer can read: the FIRMWARE partition, labelled **`ESP`** and mounted as
`/boot` on the device. Next to the boot files it already has a **`README.txt`**
and a **`dashboard-assistant.yaml.example`**, so you can copy the example, drop
the `.example`, and edit it. Put the file in the partition's root:

=== "Linux"

    Linux desktops mount the btrfs root and leave the FIRMWARE partition
    unmounted, because they treat an EFI system partition as part of the system.
    Mount it yourself; it is the first partition, the 1 GiB one:

    ```sh
    udisksctl mount -b /dev/sdX1
    ```

    Replace `sdX` with the card or disk (`lsblk` lists it), copy the file to the
    path `udisksctl` printed, and run `udisksctl unmount -b /dev/sdX1` before
    you pull it.

=== "macOS"

    Finder shows the FIRMWARE partition as a drive named **`ESP`**; the other
    partition is btrfs, which macOS cannot read. Copy the file to the root of
    `ESP` and eject the drive before you pull it.

=== "Windows"

    File Explorer shows the FIRMWARE partition as a drive named **`ESP`**; the
    other partition is btrfs, which Windows cannot read. Copy the file to the
    root of `ESP` and eject the drive before you pull it.

    !!! warning "Name the file exactly `dashboard-assistant.yaml`"

        "Hide extensions for known file types" makes
        `dashboard-assistant.yaml.example` *look* like
        `dashboard-assistant.yaml`. Turn extensions on before renaming, or the
        device will not find the file.

**It is re-read when you change it.** The device records a checksum of the file
it last imported, so:

- **first boot**: the file is applied
- **you edit it and reboot**: the new Wi-Fi is applied. This is how you move a
  device to another network: no reflash, no factory reset
- **you leave it alone**: nothing is applied, on this or any later boot
- **you delete it**: same thing. Deleting the file does not reset anything

!!! warning "The file stays on the partition"
    Importing does not delete it, and it carries your Wi-Fi password in plain
    text, so anyone who pulls the card can read it. Delete it once the device is
    set up if that matters where the device lives.

If a device does not pick the file up, the usual cause is YAML indentation. The
device cannot show you the parse error, so compare your file against the example
above: two spaces per level, and every nested key under `wifi` indented below
it.

??? tip "Or use a USB stick"

    Put `dashboard-assistant.yaml` in the root of a normal USB stick (any
    filesystem the OS can mount) and plug it into a running device. Inserting
    the stick triggers an import immediately, so you can move a device to
    another network in the field without pulling its card.

    Unlike the FIRMWARE partition, this applies **every time you plug the stick
    in**, changed or not. There is no checksum involved.

    !!! warning "Physical access = full trust"
        Any USB stick carrying a `dashboard-assistant.yaml` is applied
        automatically, and the file carries your Wi-Fi password in plain text.
        Only use seed files on hardware and networks you control, and wipe the
        stick afterwards.

Once the file is applied, the device joins your network and shows an "add me"
screen until Home Assistant adds it.

A factory reset clears the recorded checksum, so a reset device re-imports the
seed file still sitting on its card on the next boot. That is usually what you
want when re-deploying a device. When it is not, remove the file from the
partition before resetting.

## 3. Add it to Home Assistant { #integration }

The device is managed from Home Assistant through the **Dashboard Assistant**
integration. Install it once and every device on your network shows up with its
own controls and sensors: display power, brightness, pages, screenshots, OS
updates and more (see the
[entity reference](about/features.md#home-assistant-integration)).

The integration is installed from the **Marketplace** that is built into Home
Assistant (2026.11 and later) as a **custom repository**: it is not in the
Marketplace catalog, so searching alone won't find it. Custom repositories need
the Marketplace connected to GitHub.

[Open in your Home Assistant&nbsp;→](https://my.home-assistant.io/redirect/marketplace_repository/?owner=ajfriesen&repository=dashboard-assistant-integration&category=integration){ .da-btn .da-btn--primary }

1. Click the button above: it opens **Dashboard Assistant** in your Home
   Assistant's Marketplace. Or add it by hand: open
   [**Settings → Marketplace**](https://my.home-assistant.io/redirect/marketplace_discover/), choose **Add from
   link**, and paste
   `https://github.com/ajfriesen/dashboard-assistant-integration`.
2. Install **Dashboard Assistant**.
3. **Restart Home Assistant** (**Settings → System → Restart**). The
   Marketplace only copies the files; Home Assistant loads the integration on
   restart.

After the restart, Home Assistant **discovers the device on its own** over
mDNS: a "Dashboard Assistant" card appears under
[**Settings → Devices & services → Discovered**](https://my.home-assistant.io/redirect/integrations/). Click **Add** and confirm. A device that has not been
paired yet hands over its API token by itself, so there is no PIN and nothing
to type. A device set up with a seed file pairs exactly the same way.

Discovery is the only way to add a device. If the card does not appear, Home
Assistant cannot see the device's mDNS announcement, usually because the two
are on different networks or VLANs.

!!! note "A device only pairs once"
    An already-paired device refuses to hand out its token again; that is what
    keeps a stranger on your network from adopting your device. To pair it with
    a new Home Assistant instance, press its **Factory reset** button first,
    which also removes its entry. A device whose entry was deleted without a
    reset has to be reflashed before it pairs again. See
    [Recovery](usage/recovery.md).

!!! info "The connection is encrypted"
    Home Assistant talks to the display over TLS, and remembers the display's
    certificate the first time it connects. Nothing on the wire is readable by
    anyone else on your network, which matters most for the Home Assistant
    login the display is given, since that is a credential to your Home
    Assistant.

    The certificate is the display's own, so there is nothing to buy, install or
    renew. If you factory-reset the display it generates a new one, and its
    Home Assistant entry stops with an error. That is expected after a reset:
    delete the entry, and the display is discovered again and pairs. If you
    have not just reset it, take a second look.

Behind the scenes, the integration creates a dedicated **non-admin Home
Assistant user** for the device (named after it, visible under
[**Settings → People**](https://my.home-assistant.io/redirect/people/)) and logs the device's browser in with it, which is why the display
never shows a login screen. The user is removed again if you delete the
integration. If the [Music Assistant](usage/audio.md) add-on is installed, a
**Music Assistant** page is added to the device's page list automatically,
already signed in.

When a new integration release is published, the Marketplace shows an update
for **Dashboard Assistant** under [**Installed**](https://my.home-assistant.io/redirect/marketplace_installed/). Click **Update**, then restart Home Assistant.

## 4. Choose the dashboard and pages { #pages }

Open [**Settings → Devices & services → Dashboard Assistant**](https://my.home-assistant.io/redirect/integration/?domain=dashboard_assistant) and click
**Configure**:

- **Dashboard**: the device shows Home Assistant's default dashboard until you
  pick another. Admin-only dashboards are not listed, because the device signs
  in as a regular user.
- **Pages**: any number of pages, each a name and the address of any website.
  The **Page** select and the next/previous buttons switch between them, in
  this order.

Saving sends both to the device straight away.

That's it. The [Usage](usage/usage.md) guide covers the on-device controls, the
integration's entities, one-tap OS updates and rolling back if an update ever
misbehaves. If something looks off, [Recovery](usage/recovery.md) covers rolling
back and resetting the device.

[Read the usage guide&nbsp;→](usage/usage.md){ .da-btn .da-btn--ghost }
