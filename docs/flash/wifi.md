# Wi-Fi setup

A device with no network cannot be told about your network over the network. So a
freshly flashed display that cannot get online broadcasts its own Wi-Fi instead,
and you set it up from your phone. This is the same flow as a smart plug or a
robot vacuum, with one advantage: this device has a screen, so it can show you
what to join.

You do not need this if the device has Ethernet, or if you wrote a
[seed file](seed.md) before first boot. In both of those cases it goes straight
online and never broadcasts anything.

## What you do

1. **Power on the display and wait about a minute.** It first tries to find a
   network on its own. Only when that fails does it start its own.
2. **The screen shows a QR code**, along with a network name like
   `dashboard-assistant-4f2a91` and a short password.
3. **Scan the code with your phone's camera.** That joins the display's network
   without typing the password. If scanning does not work, join the network by
   hand using the name and password on the screen.
4. **A setup page opens by itself.** If nothing opens, browse to
   `http://10.42.0.1` (the screen shows this address too).
5. **Type your own Wi-Fi name and password** and tap Connect.
6. **The display's network disappears** and your phone returns to its usual one.
   That is the display joining your network. Watch the screen: it moves on to
   "Add this device in Home Assistant" and Home Assistant discovers it —
   provided the [Dashboard Assistant integration](../usage/integration.md) is
   installed there.

## Type the name exactly

The setup page asks you to type your network name rather than picking it from a
list. That is a hardware limit, not an oversight: a Wi-Fi radio cannot search for
networks while it is busy broadcasting one, so while the display is showing you
its setup network it genuinely cannot see yours. Copy the name exactly as it
appears on your phone, capitals included.

## If the password was wrong

The setup network comes back. Rejoin it, and the setup page will tell you what
went wrong, with your network name already filled in. A wrong password, a network
that is out of range and a network that simply would not accept the connection all
read differently.

## When it appears, and when it does not

The setup network only ever appears on a display that **has never been online**.
Once a display has reached your network even once, it never broadcasts again: if
it later loses Wi-Fi it shows "Reconnecting" and waits. That is deliberate. The
setup network has no protection beyond the password on the screen, so it only
exists while there is nothing on the device worth taking.

It also does not appear if the Wi-Fi adapter cannot broadcast. Some USB Wi-Fi
adapters cannot, and the display falls back to the old "Connecting" screen. Use a
[seed file](seed.md) or Ethernet on those.

To put an already-configured display back into setup mode, factory reset it from
the [admin page](../usage/admin.md). Reset also clears saved Wi-Fi, which is what
lets you move a display to a different house.

!!! note "The setup network is not a back door"
    While it is up, the display refuses admin and pairing requests that arrive
    over it. Someone who joins your display's setup network cannot factory reset
    it, roll it back, or take its Home Assistant token.
