# Seed File

A **seed file** preconfigures a device before it ever boots. Drop a
`dashboard-assistant.yaml` next to the image and the device picks up its Home
Assistant URL and Wi-Fi on first boot, which is what you want for field deploys or
for flashing several tablets at once.

For a single device you do not need one. A display that cannot get online
broadcasts its own network and you set it up from your phone: see
[Wi-Fi setup](wifi.md). A device that boots with a valid seed file joins your
network directly and never broadcasts anything.

!!! warning "Physical access = full trust"
    Any USB stick carrying a `dashboard-assistant.yaml` is applied automatically,
    and the file can carry a long-lived token in plain text. Only use seed files
    on hardware and networks you control, and wipe the stick afterwards.

## Populate Seed File

Create a file named exactly `dashboard-assistant.yaml`. Every key is optional — include
only what you want to provision:

```yaml
# Home Assistant base URL the kiosk should open.
ha_url: "https://homeassistant.local:8123"

# Optional long-lived access token for kiosk auto-login. You normally don't
# need this — the Dashboard Assistant integration provisions a login for the
# device automatically. Only set it to preset a token yourself.
token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiIyZWRlNGE0ZTFjNmQ0ZDY3OTY4ODhmMTk5OGNhNWVjMSIsImlhdCI6MTc4NDcxODk3MywiZXhwIjoyMTAwMDc4OTczfQ.Rd92pdzdYkC8HI3buVO6m9EVVI71Ye-MP_1nwogfOgU"

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
| `token`       | no       | Optional. Kiosk login token; normally provisioned by the integration. |
| `wifi.ssid`   | no       | Wi-Fi network name to join.                                      |
| `wifi.psk`    | no       | Wi-Fi pre-shared key (password).                                 |
| `api_token`   | no       | Device API token for the Home Assistant integration. Generated per device if omitted. |
| `pages`       | no       | List of `name` + `url` entries replacing the device's page list. `url` is required per entry. |

Two notes on the optional keys. `api_token` only takes effect when the daemon
next starts, so a stick plugged into a running device needs a reboot for that one
key (everything else applies immediately). And `pages` replaces the list
wholesale rather than merging, but importing it does not move the display off the
page it is showing.

## Apply the Seed File

There are two ways to hand the file to a device. Both require the image to be
built with config import enabled (`dashboard.configImport.enable = true`).

=== "`ESP / boot partition`"

    The `/boot` partition is FAT and readable on any computer. After flashing,
    mount it and copy `dashboard-assistant.yaml` to its root.

    It is imported once on first boot, while the device is still
    unprovisioned — so it seeds a fresh image without re-importing on every
    later boot.

=== "`USB stick`"

    Put `dashboard-assistant.yaml` in the root of a normal USB stick (any filesystem
    the OS can mount) and plug it into a running device.

    Inserting the stick triggers an import immediately, so you can re-provision
    a device in the field without reflashing.

Once imported, the setup wizard is skipped and the dashboard goes straight to
your Home Assistant instance.

## Pairing still works

A seeded device [pairs with Home Assistant](../usage/integration.md) exactly
like a hand-configured one: it is discovered over mDNS and hands over its API
token with nothing to type. Writing a seed file does not count as having been
paired, and there is no extra step to undo.

If pairing is refused, the device has already been paired once. That is what the
gate is for, and the way back is a factory reset from the
[admin page](../usage/admin.md).
