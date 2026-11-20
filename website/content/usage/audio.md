# Multi-room audio

The dashboard is also a speaker. It ships with a [Sendspin][sendspin] player, so
any device with sound output can join a synchronized multi-room group alongside
your other speakers — the same music, in step to well under a millisecond.

[sendspin]: https://www.sendspin-audio.com/

## What you need

Sendspin splits into a **server** that sources the music and **players** that
receive it. The dashboard is a player only. The server is [Music
Assistant][ma] — install it in Home Assistant if you don't run it already.
Nothing else on the dashboard side needs configuring: the player announces
itself over mDNS on your local network, and Music Assistant finds it and
connects to it.

[ma]: https://www.music-assistant.io/

Audio never leaves your network, and there is no cloud account anywhere in the
path.

The connection is encrypted. Sendspin can make a server **pair** with a player
before it plays, using a code the player shows. The dashboard doesn't ask for
that yet: any Music Assistant on your network can play to it, with nothing to
type.

## Using it

Once the device is on the network, it appears in Music Assistant as a player
named after the device — **Dashboard Assistant (ab12cd)**, matching the name the
Home Assistant integration uses. Send music to it like any other speaker, or add
it to a group and it stays in sync with the rest.

Volume is controlled from Music Assistant, not on the device.

## Controlling music from the dashboard

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

## Turning it off

The integration exposes a **Sendspin player** switch. Turning it off stops the
player and the device disappears from Music Assistant; turning it back on brings
it straight back. The choice survives a reboot.

The switch also carries a `status` attribute reporting what the underlying
service is actually doing (`active`, `inactive`, `failed`) — useful when a
device is switched on but has no working sound output.

## Picking a different output

Devices with more than one output — HDMI plus a USB DAC or a speaker HAT, say —
may default to the wrong one. List what the player can see:

```bash
sendspin-cli -l
```

Then set the one you want in your build, as `<backend>:<device>`:

```nix
dashboardAssistant.sendspin.output = "pipewire:alsa_output.usb-Generic_USB_Audio-00.analog-stereo";
```

Other options live alongside it: `name` overrides the player's name, `server`
makes the player connect to one server instead of waiting to be found (useful
where multicast is blocked), `bufferMs` trades latency for smoother playback,
and
`dashboardAssistant.sendspin.enable = false` leaves the audio stack out of the
image entirely.
