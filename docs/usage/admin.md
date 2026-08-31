# Admin page

The tablet's screen is deliberately dull. It shows your dashboard, a navigation
bar and a read-only info view, and nothing on it can change how the device is
configured. A shared screen gets touched by guests, housemates and children, and
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
API token, your display preferences **and saved Wi-Fi networks**, then reboots
onto the onboarding screen. You have to type `RESET` to arm the button.

Because it clears Wi-Fi, a reset display comes back broadcasting its own setup
network, which is what lets you move one to a different house. It also means a
reset knocks the display off your network, and this page has no password: anyone
who can reach it can put a display into a state that needs a phone and a walk over
to it.

Factory reset is also how you **re-pair** a device with Home Assistant. A device
hands its API token to Home Assistant automatically until Home Assistant has used
it once, and a reset puts it back in that state, so there is no code to type and
no button to press on the tablet. Remove the old entry in Home Assistant first,
because its token stops working.

You only need this for a device that is *already* in Home Assistant. One that has
never been paired pairs on its own, including a device preconfigured with a
[seed file](../flash/seed.md).

## If the network is gone

The admin page needs the network, so it cannot help a device that will not join
Wi-Fi. Three paths remain:

- If the display has never been online, it broadcasts its own setup network.
  Scan the QR code on its screen and configure Wi-Fi from your phone: see
  [Wi-Fi setup](../flash/wifi.md).
- Drop a [seed file](../flash/seed.md) on a USB stick and plug it in. The device
  applies it and restarts the kiosk.
- Pull the card or disk and read the journal directly, or reflash it.
