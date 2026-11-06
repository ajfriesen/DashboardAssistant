# Seed File

A **seed file** preconfigures a device before it ever boots. Drop a
`dashboard-assistant.yaml` next to the image and the device picks up its Wi-Fi
on first boot, which is what you want for field deploys or for flashing several
devices at once.

It also works after the fact: edit the file on the card later and the device
applies the change on its next boot, so a device can be moved to a new network
without reflashing it.

The seed file carries Wi-Fi and nothing else. Once the device is on your
network, Home Assistant discovers it, and adding it there sets up the rest: its
Home Assistant URL, the login, the dashboard and the pages (see
[Pairing still works](#pairing-still-works)).

You need one for any device that is not on Ethernet: the display has no way to ask
for Wi-Fi credentials on screen, so the seed file is how they reach it. A device
that boots with a valid seed file joins your network directly.

!!! warning "Physical access = full trust"
    Any USB stick carrying a `dashboard-assistant.yaml` is applied automatically,
    and the file carries your Wi-Fi password in plain text. Only use seed files
    on hardware and networks you control, and wipe the stick afterwards.

## Populate Seed File

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

## Apply the Seed File

There are two ways to hand the file to a device, and they differ in when they
re-apply: the boot partition is read on every boot and acted on whenever the
file has changed, while a USB stick is applied each time you plug it in.

=== "`Boot partition`"

    After flashing, the card or disk carries a small FAT partition that any
    computer can read — Windows, macOS and Linux all mount it. Copy
    `dashboard-assistant.yaml` to its root.

    It is the same partition on every image — x86 and both Raspberry Pis: the
    EFI system partition, labelled **`ESP`** and mounted as `/boot` on the
    device. On Windows and macOS your file manager shows exactly one readable
    partition, this one; the other one is btrfs, which they cannot read.

    Linux desktops do the opposite: they mount the btrfs root and leave the
    `ESP` unmounted, because they treat an EFI system partition as part of the
    system. Mount it yourself — it is the first partition, the 1 GiB one:

    ```sh
    udisksctl mount -b /dev/sdX1
    ```

    Replace `sdX` with the card or disk (`lsblk` lists it), and run
    `udisksctl unmount -b /dev/sdX1` before you pull it.

    That partition is not empty: alongside the boot files it carries a
    **`README.txt`** and a **`dashboard-assistant.yaml.example`** that say all
    of this, so a card explains itself without this page. Copy the example, drop
    the `.example`, and edit it.

    !!! warning "Name the file exactly `dashboard-assistant.yaml`"

        On Windows, "hide extensions for known file types" makes
        `dashboard-assistant.yaml.example` *look* like
        `dashboard-assistant.yaml`. Turn extensions on before renaming, or
        the device will not find the file.

    **It is re-read when you change it.** The device records a checksum of
    the file it last imported, so:

    - **first boot** — the file is applied
    - **you edit it and reboot** — the new Wi-Fi is applied. This is how you
      move a device to another network: no reflash, no factory reset
    - **you leave it alone** — nothing is applied, on this or any later boot
    - **you delete it** — same thing. Deleting the file does not reset anything

    !!! note "The file stays on the partition"

        Importing does not delete it, so anyone who pulls the card can read
        your Wi-Fi passphrase. Delete it once the device is set up if that
        matters where the device lives.

    If a device does not pick the file up, the usual cause is YAML indentation.
    The device cannot show you the parse error, so compare your file against the
    example above: two spaces per level, and every nested key under `wifi`
    indented below it.

=== "`USB stick`"

    Put `dashboard-assistant.yaml` in the root of a normal USB stick (any filesystem
    the OS can mount) and plug it into a running device.

    Inserting the stick triggers an import immediately, so you can re-provision
    a device in the field without reflashing.

    Unlike the boot partition, this applies **every time you plug the stick in**,
    changed or not. There is no checksum involved.

Once the file is applied, the device joins your network and waits for Home
Assistant to add it. After that it shows your dashboard.

## Pairing still works

A seeded device [pairs with Home Assistant](../usage/integration.md) exactly
like a hand-configured one: it is discovered over mDNS and hands over its API
token with nothing to type. Writing a seed file does not count as having been
paired, and there is no extra step to undo.

If pairing is refused, the device has already been paired once. That is what the
gate is for, and the way back is a factory reset from the
[admin page](../usage/admin.md).

A factory reset also clears the recorded checksum, so a reset device re-imports
the seed file still sitting on its card on the next boot. That is usually what
you want when re-deploying a device. When it is not, remove the file from the
partition before resetting.
