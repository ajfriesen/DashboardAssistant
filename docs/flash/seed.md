# Seed File

A **seed file** preconfigures a device before it ever boots. Drop a
`dashboard-assistant.yaml` next to the image and the device picks up its Home
Assistant URL and Wi-Fi on first boot, which is what you want for field deploys or
for flashing several tablets at once.

It also works after the fact: edit the file on the card later and the device
applies the change on its next boot, so a device can be moved to a new network or
pointed at a new Home Assistant without reflashing it.

You need one for any device that is not on Ethernet: the display has no way to ask
for Wi-Fi credentials on screen, so the seed file is how they reach it. A device
that boots with a valid seed file joins your network directly.

!!! warning "Physical access = full trust"
    Any USB stick carrying a `dashboard-assistant.yaml` is applied automatically,
    and the file can carry a long-lived kiosk token in plain text. Only use
    seed files on hardware and networks you control, and wipe the stick
    afterwards.

## Populate Seed File

Create a file named exactly `dashboard-assistant.yaml`. Every key is optional — include
only what you want to provision:

```yaml
# Home Assistant base URL the kiosk should open.
ha_url: "https://homeassistant.local:8123"

# Optional kiosk token: the long-lived Home Assistant access token the kiosk
# logs in with. You normally don't need this — the Dashboard Assistant
# integration provisions a login for the device automatically. Only set it to
# preset a kiosk token yourself.
kiosk_token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiIyZWRlNGE0ZTFjNmQ0ZDY3OTY4ODhmMTk5OGNhNWVjMSIsImlhdCI6MTc4NDcxODk3MywiZXhwIjoyMTAwMDc4OTczfQ.Rd92pdzdYkC8HI3buVO6m9EVVI71Ye-MP_1nwogfOgU"

# Optional Wi-Fi credentials. Omit the whole block on a wired device.
wifi:
  ssid: "MyNetwork"
  psk: "supersecret"

# Optional device API token, the credential Home Assistant uses to talk to this
# device. Leave it out and the device generates its own, which Home Assistant
# picks up when it pairs. Set it to flash a fleet with a token you already know.
api_token: "a-long-random-string"

# Optional list of dashboard pages, replacing whatever the device has. `name` is
# the label in Home Assistant; without one the URL is its own label.
pages:
  - name: "Home"
    url: "https://homeassistant.local:8123/lovelace/0"
  - name: "Kitchen"
    url: "https://homeassistant.local:8123/lovelace/kitchen"
```

| Key           | Required | Description                                                      |
| ------------- | -------- | ---------------------------------------------------------------- |
| `ha_url`      | no       | Home Assistant base URL the dashboard loads on boot.             |
| `kiosk_token` | no       | Kiosk token the dashboard logs in with; normally provisioned by the integration. |
| `wifi.ssid`   | no       | Wi-Fi network name to join.                                      |
| `wifi.psk`    | no       | Wi-Fi pre-shared key (password).                                 |
| `api_token`   | no       | Device API token for the Home Assistant integration. Generated per device if omitted. |
| `pages`       | no       | List of `name` + `url` entries replacing the device's page list. `url` is required per entry. |
| `token`       | no       | Deprecated name for `kiosk_token`, still applied. Ignored when `kiosk_token` is also present. |

Three notes on the optional keys. `api_token` only takes effect when the daemon
next starts, so a stick plugged into a running device needs a reboot for that one
key (everything else applies immediately) — editing the file on the boot
partition always applies it, because that is read during boot anyway. And `pages`
replaces the list wholesale rather than merging, though importing it does not
move the display off the page it is showing. Finally, `kiosk_token` used to be
called `token`: a file using the old name is still applied, and the device notes
the rename in `journalctl -u dashboard-assistant-boot-import`. Rename the key
anyway — a bare `token` next to `api_token` does not say which credential it is.

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
    device. Your file manager shows exactly one readable partition; the other
    one is btrfs, which Windows and macOS cannot read.

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
    - **you edit it and reboot** — the new values are applied. This is how you
      re-provision a device in place: no reflash, no factory reset
    - **you leave it alone** — nothing is applied, on this or any later boot.
      Changes you made on the device or from Home Assistant are kept
    - **you delete it** — same thing. Deleting the file does not reset anything

    !!! warning "An edit applies the whole file"

        Not just the line you changed. That matters for `pages`, which replaces
        the device's page list outright — so if you edit `ha_url` on a device
        whose pages you have since reordered in Home Assistant, the file's page
        list wins. Delete the `pages` block to manage pages from Home Assistant
        instead.

    !!! note "The file stays on the partition"

        Importing does not delete it. If it carries a Wi-Fi passphrase, anyone
        who pulls the card can read it — so delete it once the device is set up
        if that matters where the device lives.

    If a device does not pick the file up, the usual cause is YAML indentation.
    The device logs what it did, and any parse error, under
    `journalctl -u dashboard-assistant-boot-import`.

=== "`USB stick`"

    Put `dashboard-assistant.yaml` in the root of a normal USB stick (any filesystem
    the OS can mount) and plug it into a running device.

    Inserting the stick triggers an import immediately, so you can re-provision
    a device in the field without reflashing.

    Unlike the boot partition, this applies **every time you plug the stick in**,
    changed or not. There is no checksum involved.

Once the file is applied, the device goes straight to your Home Assistant
dashboard.

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
