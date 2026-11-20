# Use cases

Once provisioned, the device boots straight into your Home Assistant dashboard
and stays there. Day-to-day you control it in two places: **on the screen
itself** and **from Home Assistant** through the native integration.

## On the device

A small bar gives you touch controls without leaving the kiosk:

- **Next / Previous page** — cycle through your configured dashboard URLs.
- **⌨ Keyboard** — toggle the on-screen keyboard for text fields on touch-only
  devices *(experimental)*.
- **Touch to wake** — tapping the screen wakes the display when it has slept.

Turn off the **Button bar** switch in Home Assistant to hide the bar and give
the dashboard the whole screen. Its buttons go with it, so the on-screen
keyboard can't be opened while the bar is hidden.

## From Home Assistant

Install the **Dashboard Assistant** integration
([from the Marketplace](../getting-started.md#integration)) and Home Assistant discovers the device over mDNS
as a single device and pairs itself. A device that has not been added yet hands
over its API token automatically, so there is nothing to type. From there you
can:

- Turn the **display** on/off and set **brightness**.
- Adjust **zoom** and flip **dark mode**.
- Show or hide the **button bar**.
- **Rotate** the display to 0, 90, 180 or 270°.
- Show the **screen saver** now, pick its style, or set how long the panel
  waits without a touch before it starts (10 minutes by default; 0 turns it
  off). A tap dismisses it.
- Take a **screenshot** of the current view on demand.
- Switch the active **page**, and choose the dashboard and pages (any website)
  under **Configure** on the integration card.
- Turn the **Sendspin player** on or off — see [Multi-room audio](#audio).
- **Reboot** or **shut down** the device.
- Install an **OS update** when one is available.

It also reports sensors — CPU, memory, storage, temperature, uptime, battery
(when present) and idle time — so you can build automations (for example, dim
the panel at night or wake it on motion).

See the [Home Assistant integration](features.md#home-assistant-integration)
reference for the complete entity list.

## Updates

OS updates are atomic and surface in Home Assistant as an `update` entity: it
compares the installed version against the latest release and offers a one-tap
install. Every version is kept as a NixOS generation, so if an update misbehaves
you can roll back (see [Recovery](#recovery)).

## Multi-room audio { #audio }

The dashboard is also a speaker. It ships with a [Sendspin][sendspin] player, so
any device with sound output can join a synchronized multi-room group alongside
your other speakers — the same music, in step to well under a millisecond.

[sendspin]: https://www.sendspin-audio.com/

### What you need

Sendspin splits into a **server** that sources the music and **players** that
receive it. The dashboard is a player only. The server is [Music
Assistant][ma] — install it in Home Assistant if you don't run it already.
Nothing else on the dashboard side needs configuring: the player discovers the
server over mDNS on your local network and connects on its own.

[ma]: https://www.music-assistant.io/

Audio never leaves your network, and there is no cloud account anywhere in the
path.

One server-side setting matters: Music Assistant can ask players to **pair** with
a PIN, and can be told to *require* it. Unpaired players are allowed by default,
which is what the dashboard relies on — it has no way to be handed a PIN. Leave
unpaired access enabled for it under the Sendspin settings in Music Assistant.

### Using it

Once the device is on the network, it appears in Music Assistant as a player
named after the device — **Dashboard Assistant (ab12cd)**, matching the name the
Home Assistant integration uses. Send music to it like any other speaker, or add
it to a group and it stays in sync with the rest.

Volume is controlled from Music Assistant, not on the device.

### Controlling music from the dashboard

When Music Assistant is installed as the Home Assistant **add-on**, the
integration adds a **Music Assistant** page to the device automatically. Pick it
from the `Page` select entity, or swipe to it on the tablet, and the full Music
Assistant interface comes up on screen — browse the library, and send what you
pick to the device's own player or to any other speaker in the house.

Nobody has to log in. Music Assistant 2.7 made a login mandatory and keeps its
own accounts, separate from Home Assistant's, but the add-on is reached through
Home Assistant's Ingress: it is told who is signed in and creates a matching
Music Assistant account with no password. The tablet is already signed into Home
Assistant, so it is already signed into Music Assistant.

Two things are worth knowing:

- That account is a regular, non-admin one. If the dashboard shows no speakers or
  no music, an admin may have to grant it access under **Settings → User
  Management** in Music Assistant.
- If the browser is ever signed out of Home Assistant it comes back on the Home
  Assistant dashboard, not this page — same as a fresh boot. Swipe back.

A **standalone** Music Assistant server — one that is not a Home Assistant add-on
— gets no page, because without Ingress there is nothing to sign the tablet in
with. Add its URL as a page by hand (under **Configure**, see
[Choose the pages](../getting-started.md#pages))
and log in once on the device.

### Turning it off

The integration exposes a **Sendspin player** switch. Turning it off stops the
player and the device disappears from Music Assistant; turning it back on brings
it straight back. The choice survives a reboot.

The switch also carries a `status` attribute reporting what the underlying
service is actually doing (`active`, `inactive`, `failed`) — useful when a
device is switched on but has no working sound output.

### Picking a different output

Devices with more than one output — HDMI plus a USB DAC or a speaker HAT, say —
may default to the wrong one. List what the player can see:

```bash
sendspin-player --list-audio-devices
```

Then set the one you want in your build:

```nix
dashboardAssistant.sendspin.audioDevice = "USB Audio Device";
```

The name has to match exactly, including any `(hw:X,Y)` suffix. Other options
live alongside it: `name` overrides the player's name, `server` pins it to one
server instead of discovering one (useful where multicast is blocked),
`bufferMs` trades latency for resilience on flaky Wi-Fi, and
`dashboardAssistant.sendspin.enable = false` leaves the audio stack out of the
image entirely.

## Remote access (VNC) { #remote-access }

Some things are hard to do on a wall-mounted touchscreen, like signing in to
Google Calendar so a calendar page can show your events. For those, the
dashboard can run a VNC server. You see its screen on your computer and use
your own keyboard and mouse, and whatever you do happens on the device.

VNC is **off** until you switch it on in Home Assistant. It switches itself off
again after a timeout, and it is always off after the device restarts.

### Switching it on

The device has two entities in Home Assistant:

- **VNC**: a switch that starts and stops the server.
- **VNC timeout**: how many minutes VNC stays on before it closes by itself,
  15 by default. Set it to 0 to keep VNC on until you switch it off.

Turn on the **VNC** switch and open its details. The attributes show
everything you need to connect:

| Attribute   | What it is                                     |
|-------------|------------------------------------------------|
| `address`   | Where to connect, e.g. `192.168.1.50:5900`     |
| `username`  | Always `dashboard`                             |
| `password`  | A new random password, made for this session   |
| `closes_at` | When VNC switches itself off                   |

Every time VNC is switched on, the device makes a new password. Once the
session ends, the old password stops working. Home Assistant keeps the password
out of its history and out of diagnostics downloads.

While VNC is on, the device shows a red **● Remote access** marker on its
bottom bar, so anyone in front of it knows the screen may be watched. If you
have hidden the bar with the **Button bar** switch, the marker is hidden too.
Switching VNC on also turns the screen on and closes the screen saver.
Otherwise you would be looking at a dark panel.

### Which VNC app to use

The connection is always encrypted, and the device refuses VNC apps that can't
encrypt it. These apps work:

- [TigerVNC](https://tigervnc.org/) 1.13 or newer (Windows, macOS, Linux)
- [RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/) (all platforms, including phones)
- [Remmina](https://remmina.org/) (Linux)

The **Screen Sharing** app built into macOS does not work, because it can't
encrypt the connection the way the device requires. Use TigerVNC or RealVNC
Viewer on a Mac.

The first time you connect, your VNC app may ask you to confirm the device's
key or certificate. Accept it. The key stays the same from one session to the
next, so the app only asks again after a factory reset.

### Good to know

- Your mouse and keyboard work, but the device doesn't count them as touches.
  If a Home Assistant automation turns the screen off some time after the last
  touch, it may do so while you're connected. Pause it, or raise its delay,
  while you work.
- VNC only answers on your local network, like the rest of the device.
- If you don't want remote access at all, leave the switch off. Nothing listens
  for VNC connections while it is off.

## Recovery { #recovery }

The device's screen is deliberately dull. It shows your dashboard, a navigation
bar and a read-only info view, and nothing on it can change how the device is
configured. A shared screen gets touched by guests, housemates and children, and
none of them should be able to roll it back or reset it.

So recovery runs from Home Assistant, on the device's page under
**Settings → Devices & services → Dashboard Assistant**. Every request carries
the token the device handed Home Assistant when it paired, and nothing else on
your network can roll the device back or reset it.

[![Open your Home Assistant instance and show the Dashboard Assistant integration.](https://my.home-assistant.io/badges/integration.svg)](https://my.home-assistant.io/redirect/integration/?domain=dashboard_assistant)

### Roll back an update

Every update is kept as a NixOS generation, so the previous version is still
on the device. If an update broke something, press **Roll back**. The device
switches to the generation before the current one and reboots, and keeps
booting that one until it updates again.

On a device that has only one generation, such as a freshly flashed one, the
press is refused: there is nothing to go back to.

!!! note "Automatic rollback isn't on yet"
    An update that stops the device from reaching the network cannot be rolled
    back from Home Assistant, because Home Assistant cannot reach it either.
    Booting the previous generation automatically after a failed boot will cover
    that case; until it is switched on, reflash the device, or plug in a keyboard
    and pick an earlier generation from the boot menu.

### Factory reset

**Factory reset** clears the device's pairing, its display preferences, its
page list **and its saved Wi-Fi networks**, then reboots. Home Assistant removes
the device's entry at the same time, because the device comes back with a new
token that the old entry could never use.

A reset is how you move a device to another Home Assistant, or to another house:

- **On Ethernet** it comes back on its own, and Home Assistant discovers it
  again.
- **On Wi-Fi** it reads the [seed file](../getting-started.md#seed-file) again if one is still
  on its boot medium, and joins that network. If you deleted it, or the device
  is moving to another network, write a new one first.

Once it is back on the network, add it again from the discovered card, the way
[Home Assistant integration](../getting-started.md#integration) describes.

### If the entry is already gone

A device pairs once. If its entry was deleted without a factory reset first, or
the Home Assistant it belonged to was reinstalled without a backup, the device
still holds its old pairing and refuses to pair again. Nothing on the network
can undo that, by design: otherwise anyone on your network could adopt your
device. [Reflash it](../getting-started.md#flash) and seed it again.

### If the network is gone

Home Assistant needs to reach the device, so it cannot help one that will not
join the network.

- Drop a [seed file](../getting-started.md#seed-file) on a USB stick and plug it in. The device
  applies it, which is the way back onto Wi-Fi.
- Plug in Ethernet, which needs no configuration at all.
- Pull the card or disk and read the journal directly, or reflash it.
