# Admin page

The tablet's screen is deliberately dull. It shows your dashboard, a navigation
bar and a read-only info view, and nothing on it can change how the device is
configured. A wall panel gets touched by guests, housemates and children, and
none of them should be able to re-point it, roll it back or reboot it.

Everything that *does* change the device lives on the **admin page**, which you
open from another machine on the same network:

```
http://<device-ip>:8099/
```

The IP is on the tablet itself: tap **❤** on the bottom bar, then the **ⓘ** in
the top-right corner.

!!! warning "The admin page has no password"
    Anyone who can reach the device on your network can open it and factory-reset
    the tablet. That is a deliberate trade for being able to recover a device
    whose screen offers no way in, but it does mean the device belongs on a
    network you trust, not a shared or guest one. The page hands out no
    credentials, and the Home Assistant API token is never shown there.

## What it does

**Device.** Read-only identity and network details: name, hostname, MAC, IP,
machine ID, model, serial, installed version and the Home Assistant URL. The same
view the **ⓘ** button shows on the tablet.

**Recovery.** Pick an earlier system generation and boot into it. Use this when
an update broke something. The device switches generation and reboots, and keeps
booting that one until you deploy again.

**Factory reset.** Clears the Home Assistant URL, the login token, the device
API token and your display preferences, then reboots onto the onboarding screen.
You have to type `RESET` to arm the button.

Factory reset is also how you **re-pair** a device with Home Assistant. A device
that has been reset is unprovisioned, and an unprovisioned device hands its API
token to Home Assistant automatically over mDNS discovery, so there is no code
to type and no button to press on the tablet. Remove the old entry in Home Assistant
first, because its token stops working.

## If the network is gone

The admin page needs the network, so it cannot help a device that will not join
Wi-Fi. Two paths remain:

- Drop a [seed file](../flash/seed.md) on a USB stick and plug it in. The device
  applies it and restarts the kiosk.
- Pull the card or disk and read the journal directly, or reflash it.
