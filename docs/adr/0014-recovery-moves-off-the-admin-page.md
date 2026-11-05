---
status: proposed
---

# Recovery moves off the admin page

A device stops serving the **admin page**. **Recovery** arrives two other ways: Home Assistant runs it for a device that is still paired, and boot counting ([0009](0009-updates-switch-generations-and-roll-back-automatically.md)) runs it for an update that never reaches a good boot. A device that Home Assistant has lost is reflashed. This replaces the half of [0001](0001-seed-file-is-the-only-way-to-configure-a-device.md) that put recovery on the admin page; the seed file is still the only way to configure a device.

The admin page is unauthenticated, so anyone who can reach the device on the network can factory-reset it, and a reset forgets the Wi-Fi, so it ends with someone carrying a card to the device. That was the price of recovering a device whose screen offers no way in. Checked against what the page actually does, the price buys almost nothing:

- **Device info** repeats the on-screen ⓘ view and the integration's diagnostic sensors.
- **Rollback** is needed when an update broke something. If it broke the daemon or the network, the page is gone too, because the daemon serves it. If it did not, Home Assistant can reach the device and can run the rollback behind the device token.
- **Factory reset** of a paired device can also run from Home Assistant. What is left is the device whose entry is gone (Home Assistant reinstalled without a backup, the entry deleted): a paired device refuses to pair again, nobody can type its token, and only a reset opens pairing. Reflashing opens it too and ends in the same state — no Wi-Fi, pairing open, a seed file needed — so that case needs no mechanism of its own.

## Considered Options

- **Keep the admin page and add a password.** Rejected: the device would have to ship with or display a credential. A printed default is a well-known weakness, and showing one on the screen hands it to everyone who can touch the screen, which is who the page was kept away from.
- **Keep the admin page for factory reset only.** Rejected: that is the destructive half, still unauthenticated, kept for a case that needs physical access anyway.
- **A reset file on the boot medium or a USB stick**, acted on once and deleted. Rejected for now: on a Pi it saves nothing over reflashing the card it would sit on, and it would add a second watched file with its own edge cases (a read-only stick, a file that cannot be deleted and would reset on every boot). It earns its place only if reinstalling an x86 device from an installer stick turns out to be painful, and nothing here stands in its way then.
- **A gesture on the touchscreen** (long press, tap pattern). Rejected by the same reasoning as 0001: guests touch the screen, and a gesture written in the docs is a gesture anyone can look up.
- **A `reset:` key in the seed file.** Rejected: the seed file carries Wi-Fi only, and is re-read whenever it changes, so a reset could be applied by accident while someone edits the Wi-Fi.

## Consequences

- The integration gains a factory-reset button and a rollback action. A reset from Home Assistant leaves an entry whose token no longer works, so the integration removes the entry itself, and discovery offers the device again once it is back on the network. Because a reset forgets the Wi-Fi, a device on Wi-Fi only comes back after a new seed file. The button says so.
- Removing a device from Home Assistant without resetting it first means reflashing it before it pairs again. The integration's removal path and the docs say so, and steer towards the reset button instead.
- Until boot counting is switched on, an update that kills the daemon or the network has no remote recovery at all, which is also true today because the admin page is served by the same daemon. The way out is to reflash, or to pick an earlier generation from the systemd-boot menu with a keyboard.
- Port 8099 closes, `modules/core/admin.nix` and `daemon/admin.go` go, and the **admin page** and its wording leave `CONTEXT.md`. **Recovery** stays as a term, defined by what it does rather than where it happens.
- The website's admin page is rewritten into a recovery page: from Home Assistant, or by reflashing.
