# Multi-room audio

The dashboard is also a speaker. It ships with a [Sendspin][sendspin] player, so
any device with sound output can join a synchronized multi-room group alongside
your other speakers — the same music, in step to well under a millisecond.

[sendspin]: https://www.sendspin-audio.com/

## What you need

Sendspin splits into a **server** that sources the music and **players** that
receive it. The dashboard is a player only. The server is [Music
Assistant][ma] — install it in Home Assistant if you don't run it already.
Nothing else on the dashboard side needs configuring: the player discovers the
server over mDNS on your local network and connects on its own.

[ma]: https://www.music-assistant.io/

Audio never leaves your network, and there is no cloud account anywhere in the
path.

## Using it

Once the device is on the network, it appears in Music Assistant as a player
named after the device — **Dashboard Assistant (ab12cd)**, matching the name the
Home Assistant integration uses. Send music to it like any other speaker, or add
it to a group and it stays in sync with the rest.

Volume is controlled from Music Assistant, not on the device.

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
