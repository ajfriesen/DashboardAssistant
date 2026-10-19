# Dashboard Assistant OS

The operating system image that turns a mini-PC or Raspberry Pi into a dedicated Home Assistant dashboard, which Home Assistant can in turn see and control.

## Language

**Dashboard Assistant**:
The product: this OS plus its Home Assistant integration. In code and package names it is `dashboard-assistant`; `dashboardassistant.org` is only the domain.
_Avoid_: DashboardAssistant, DashboardAssistant.org (as a product name)

### The device

**Device**:
One physical unit running Dashboard Assistant OS: a mini-PC or Raspberry Pi with a display.
_Avoid_: tablet, screen, kiosk (for the unit)

**Kiosk**:
The display layer of a device: a locked-down compositor showing a single fullscreen browser.
_Avoid_: using it for the whole device

**Dashboard**:
The Home Assistant page the kiosk shows.

**App**:
A capability built into the image and switched on per device, like Sendspin. Apps ship in a generation; a device never installs one at runtime.
_Avoid_: add-on, plugin, service

**Sendspin**:
The music player running on a device that lets audio be streamed to it.

**FIRMWARE partition**:
The small FAT partition every board has, readable from any computer, where the boot files and seed file live.
_Avoid_: ESP, seed drop zone (in prose)

**Board**:
A hardware target the OS is built for: `x86_64`, `rpi4` or `rpi5`.
_Avoid_: arch, board token, platform

### Getting a device onto Home Assistant

**Seed file**:
The `dashboard-assistant.yaml` file a user places on the device's FIRMWARE partition or a USB stick to give it its Home Assistant URL, Wi-Fi and, optionally, its kiosk token and device API token.
_Avoid_: seed data, config file

**Seeding**:
The device reading a new or changed seed file and applying it.
_Avoid_: import, provisioning (as a verb)

**Provisioned**:
The state of a device that knows its Home Assistant URL. It says nothing about whether Home Assistant knows the device.
_Avoid_: set up, configured

**Integration**:
The Home Assistant custom integration, shipped separately, through which Home Assistant pairs with and controls devices.
_Avoid_: add-on, component

**Device API token**:
The credential Home Assistant uses to talk to a device. Generated per device unless the seed file presets it.
_Avoid_: bare "token", API key

**Kiosk token**:
The Home Assistant long-lived access token the kiosk logs in with. Normally supplied by the integration.
_Avoid_: bare "token", HA token

**Paired**:
The state of a device whose device API token the integration has used. Pairing happens once; removing the integration does not unpair a device, only a factory reset does.
_Avoid_: connected, enrolled, provisioned (a different state)

### Talking to Home Assistant

**Device API**:
The authenticated API a device serves on the local network for the integration. Home Assistant always opens the connection; a device never calls Home Assistant. Distinct from the admin page, which serves people.
_Avoid_: local API, REST API

**State stream**:
The connection a device holds open to push snapshots to Home Assistant.
_Avoid_: event stream, websocket, push channel

**Snapshot**:
One complete picture of a device's state. Every state message is a whole snapshot, never a delta.
_Avoid_: state update, patch, diff

### Keeping a device alive

**Admin page**:
The page a device serves on the local network for maintenance; it is where recovery happens.
_Avoid_: settings page, config panel

**Recovery**:
The admin-page actions that bring a misbehaving device back: rolling back to an earlier generation, or a factory reset. Not a boot mode.
_Avoid_: rescue, recovery mode

**Generation**:
One bootable version of a device's installed system; recovery can return to an earlier one.

**Good boot**:
A boot after which the device is reachable on the local network, so recovery is possible. A blank screen or an unreachable Home Assistant does not make a boot bad.
_Avoid_: healthy boot, successful boot

**Automatic rollback**:
The device returning by itself to the previous generation after a generation repeatedly fails to reach a good boot.
_Avoid_: auto-recovery, failover

**Rejected release**:
A release a device automatically rolled back from. The device skips it until a newer release ships.
_Avoid_: bad release, failed update

### Builds and releases

**Candidate**:
A release whose images are published but not yet promoted. Devices never see one, and nothing links to it.
_Avoid_: rc (a hyphened tag, which a candidate need not be), build

**Promotion**:
Marking a candidate as the release users get: the newest release devices offer to install, and the one the download links point at. The images do not move; only the pointers do.
_Avoid_: publish (the images already are), release (ambiguous)

**Channel**:
A release stream a device can follow: `release`, `pre-release` or `dev` (branch builds). Never "unstable", which only names the NixOS branch every board is built from.

**Dev image**:
An image built with root SSH access and a root password, for development on real hardware. Unrelated to the dev channel; always say "dev image" or "dev channel", never bare "dev".

**Bench**:
The physical Raspberry Pi 5 rig for running tests on real hardware.
_Avoid_: lab, rig, testbed

**Bench host**:
The always-on machine the bench is plugged into. It owns the hardware and the identity of every part of it, and makes the bench available to whichever machine runs the tests. It is never itself a board under test.
_Avoid_: test server, runner, lab PC

**Bench Home Assistant**:
The Home Assistant the bench's devices pair with, running on the bench host. Pinned, and reset to a known state before each run, so a failure is the image's and never yesterday's leftovers.
_Avoid_: test HA, mock HA, fake HA

**Bench Wi-Fi**:
The dedicated SSID the bench's devices join to exercise Wi-Fi seeding.
_Avoid_: test wifi, lab wifi

**Release gate**:
The suite on the bench a candidate must pass before promotion.
_Avoid_: CI, hardware CI

