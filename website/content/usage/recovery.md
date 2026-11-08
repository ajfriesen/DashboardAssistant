# Recovery

The device's screen is deliberately dull. It shows your dashboard, a navigation
bar and a read-only info view, and nothing on it can change how the device is
configured. A shared screen gets touched by guests, housemates and children, and
none of them should be able to roll it back or reset it.

So recovery runs from Home Assistant, on the device's page under
**Settings → Devices & services → Dashboard Assistant**. Every request carries
the token the device handed Home Assistant when it paired, and nothing else on
your network can roll the device back or reset it.

## Roll back an update

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

## Factory reset

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

## If the entry is already gone

A device pairs once. If its entry was deleted without a factory reset first, or
the Home Assistant it belonged to was reinstalled without a backup, the device
still holds its old pairing and refuses to pair again. Nothing on the network
can undo that, by design: otherwise anyone on your network could adopt your
device. [Reflash it](../getting-started.md#flash) and seed it again.

## If the network is gone

Home Assistant needs to reach the device, so it cannot help one that will not
join the network.

- Drop a [seed file](../getting-started.md#seed-file) on a USB stick and plug it in. The device
  applies it, which is the way back onto Wi-Fi.
- Plug in Ethernet, which needs no configuration at all.
- Pull the card or disk and read the journal directly, or reflash it.
