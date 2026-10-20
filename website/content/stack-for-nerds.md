---
icon: lucide/cpu
---

# Stack for Nerds

The technical bits, for the curious. If you just want a dashboard on your wall,
the [landing page](index.md) and [Get started](getting-started.md) guide are all
you need — this page is about *how* it works under the hood.

## Built on NixOS

Dashboard Assistant OS is a minimal, **declarative NixOS** system.

- **Reproducible.** The whole system is defined in code. The image you flash is
  the system you run — there's no hand-configuration to drift over time.
- **Atomic updates, delivered through Home Assistant.** New versions appear as
  an `update` entity — install with one tap, no terminal and nothing to
  re-flash. An update either fully applies or not at all, and each version is
  kept as a NixOS *generation*.
- **Boots straight into a kiosk.** No desktop, no display manager, no login
  screen — just a full-screen Chromium locked to your dashboards.

## Recovery & rollback

Because every version is retained as a generation, you can always go back.

- **Manual rollback (available today).** The LAN-only
  [admin page](usage/admin.md) lets you boot an older, known-good generation
  from any machine on your network — useful if a configuration change
  misbehaves but the system still boots. The touchscreen itself is read-only,
  so nobody at the panel can roll the device back.
- **Automatic rollback.** A new generation's boot entry is written with a
  counter: **systemd-boot** decrements it on every attempt, and an entry whose
  counter reaches zero is marked bad and skipped in favour of the previous
  generation. The counter is cleared — the boot *blessed* — only once the
  device is reachable on the network, which is what this OS means by a **good
  boot**; a blank screen or an unreachable Home Assistant does not count,
  because neither is the update's fault and rolling back for them would loop.
  Three attempts, then the device is back on the release it came from. Every
  release a device has turned down is written to its state directory and skipped
  until a newer one ships — written down rather than derived, because the
  evidence a rollback leaves behind (the system profile still pointing at the
  abandoned generation) disappears at the next update, and a device that turned
  down two releases would otherwise alternate between them. A rejected release
  stays in the version picker, and installing one successfully takes it off the
  list.

  This is systemd's [Automatic Boot
  Assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/), and it is the
  reason every target boots through systemd-boot — on the Raspberry Pi, U-Boot
  stays in the chain only to provide the UEFI environment it runs in. Both
  bootloader installs pass `--no-variables` and rely on the removable fallback
  path, so whether a loader that may not touch NVRAM can still count boots is
  asserted rather than assumed: in a VM for x86 (`tests/good-boot.nix`) and on
  the hardware bench for the Pi.

  A freshly flashed device has a single generation and nothing to fall back to.
  If it never reaches a good boot it keeps trying that one, and the fix is to
  reflash: automatic rollback protects updates, not flashing.

## Storage & flash wear

Every device boots from flash — an SD card on the Raspberry Pi, eMMC or an SSD on
x86. On an SD card the write budget is the scarcest resource on the board, and a
dashboard that is powered on 24/7 for years will find the limit. So the OS is
built to keep the things that write constantly *off* the card.

**What lives in RAM**

- **The system journal.** Logs are written to a tmpfs and copied onto the card
  once an hour, and again on a clean shutdown. A single misbehaving service once
  wrote 2.87 GB to an SD card in one boot; that is no longer possible.
- **Chromium's caches.** The browser's HTTP cache and compiled-JavaScript cache
  are the heaviest repeat writers after logging, and both re-fetch from your
  Home Assistant in well under a second. They are capped at 64 MiB in RAM.
- **`/tmp`,** so nothing scratch ever reaches the card.
- **Screenshots.** The frame behind the Home Assistant screenshot entity is
  handed between processes through RAM. How often it is taken is up to your
  automation, so this one had no upper bound at all before.

**What that costs you.** A power cut loses up to an hour of logs — the hour since
the last sync. On a panel that people unplug, that is a real trade, taken
deliberately: the alternative is every log line hitting the card forever. If you
would rather have crash-time logs than card life, one line gets you back to
stock behaviour:

```nix
services.journald.storage = "persistent";
```

**What is on the card, and tuned for it.** The root filesystem is **btrfs** with
`zstd` compression and `noatime`, so reads never cause writes and everything
written is compressed first. Swap is **compressed RAM** (zram), never a swap file
— so swapping costs no writes at all. Partitions are aligned to 1 MiB and the
root filesystem grows to fill the card on first boot, which avoids the
write-amplification that comes from misaligned partitions. TRIM runs weekly.

!!! tip "Check what your device is actually writing"

    If you suspect a dying card, measure before replacing it. Field 10 of
    `/proc/diskstats` is sectors written since boot, in 512-byte units:

    ```bash
    w() { awk -v d="$1" '$3==d{print $10}' /proc/diskstats; }
    dev=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
    a=$(w "$dev"); sleep 3600; b=$(w "$dev")
    echo "$(( (b-a)*512/1024 )) KiB in 1 h  ($(( (b-a)*512/1024*24/1024 )) MiB/day)"
    ```

    To see *which* service is responsible:

    ```bash
    systemd-cgtop --order=io -b -n 3
    ```

    Note that btrfs does not attribute metadata and delayed writes back to the
    service that caused them, so treat `systemd-cgtop` as a ranking rather than
    a measurement — `/proc/diskstats` is the honest total.

    SD cards expose no standard wear counter, which is why there is no "card
    health" sensor. eMMC and NVMe do:

    ```bash
    mmc extcsd read /dev/mmcblk0 | grep -iE 'life time|pre.?eol'   # eMMC
    nvme smart-log /dev/nvme0 | grep -E 'data_units_written|percentage_used'
    ```

## Home Assistant integration

The panel doesn't just *show* Home Assistant — it reports back into it as a
device.

- A **first-party integration**, installable
  [via HACS](usage/integration.md) as a custom repository.
- Home Assistant **discovers the device over mDNS** and claims the API token
  itself while the device is still unprovisioned, so there is no code to type.
- **No MQTT broker required** — it talks to Home Assistant directly.
- Exposes controls and sensors: display on/off, brightness, zoom, dark mode,
  rotation, screenshot, reboot / shutdown, updates, plus battery, temperature,
  CPU, memory and storage.

See the [entity reference](about/features.md#home-assistant-integration) for the
full list.

## Provisioning

On Ethernet a device gets online by itself and Home Assistant discovers it from
there. Everything else — Wi-Fi credentials included — comes from a small
**YAML seed file** (Home Assistant URL, token, Wi-Fi, dashboard URLs, optional
integration token) dropped on a USB stick or the boot partition configures the
device before it ever boots. Either way, nothing on the running panel can
re-point the device: the screen shows a read-only info view and nothing else;
rollback and factory reset live on a LAN-only admin page.

## Hardware

x86_64 is the primary, tested target today. Raspberry Pi and other aarch64
boards are a work in progress — see [Hardware Support](hardware-support/index.md) for
the current state.

## Development

Dashboard Assistant is under active development on
[GitHub](https://github.com/ajfriesen/DashboardAssistant) — issues and pull
requests are welcome.
