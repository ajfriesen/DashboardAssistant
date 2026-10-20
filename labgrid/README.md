# Hardware bench

Automated first-boot tests on a real Raspberry Pi 5, driven by
[labgrid](https://labgrid.readthedocs.io/).

```
just build-rpi5-dev   # build the image
just hw-test          # flash it, boot the board, assert
```

`tests/first-boot.nix` already covers everything a VM can reach, and CI runs it on
every push. What it cannot reach is the part of this OS that only exists on
hardware: the Pi's boot chain (GPU firmware → U-Boot → systemd-boot → Linux), the
btrfs root on a real SD card, first-boot growfs, the FAT firmware partition, and
the kiosk session on a real GPU. That is what this directory is for, and
`test_first_boot.py` deliberately repeats the VM test's assertions alongside the
hardware-only ones.

## The bench

The hardware is not attached to the machine running the tests. It hangs off the
**bench host**, which exports it through a labgrid coordinator; the tests acquire
the place and drive it from wherever they run. See
[ADR 0010](../docs/adr/0010-the-bench-is-driven-through-a-labgrid-coordinator.md).

```
   ┌──────────────────────┐              ┌───────────────────────────┐
   │  your machine        │   gRPC       │  bench host               │
   │                      │  :20408      │                           │
   │  pytest / labgrid ───┼──────────────┤  labgrid-coordinator      │
   │  labgrid-client      │              │  labgrid-exporter         │
   │                      │   ssh        │   ├── usbsdmux + dd       │
   │  the built image ────┼──────────────┤   └── ser2net             │
   └──────────────────────┘  rsync + dd  └────┬──────────────┬───────┘
                                              │ USB          │ USB
                        ┌──────────┐     ┌────┴─────┐   ┌────┴────────┐
             HTTP ──────┤  Shelly  │     │ USB-SD-  │   │ Debug Probe │
            (plug)      │  (mains) │     │ Mux+card │   └────┬────────┘
                        └────┬─────┘     └────┬─────┘        │
                             │ power          │ card         │ UART
                           ┌─┴────────────────┴──────────────┴─┐
                           │        Raspberry Pi 5             │
                           └───────────────────────────────────┘
```

Everything is reached through the place: `NetworkUSBSDMuxDevice`,
`NetworkSerialPort` and `NetworkPowerPort`. The exporter runs `--isolated`, so
each resource carries `proxy_required` and is reached over ssh to the bench host —
the `dd` and the `usbsdmux` calls run *there*, and the console comes back over
ser2net as rfc2217.

**The hardware identities live in the bench host's NixOS module**, not here: the
mux serial, the probe serial and interface, and the plug's model, address and
index. `bench.yaml` names the place and nothing else, deliberately — the copy
this repo used to carry had already drifted (it did not know about the plug). To
see what the exporter publishes:

```sh
just hw-status                         # the place, its resources, who holds it
labgrid-client -p "$LG_PLACE" resources
```

An SD card has to be sitting in the mux. `just hw-preflight` checks for one
before anything is written — without that check you get a "timeout while waiting
for medium" from the write step several minutes in, which does not name the
cause. The card is also the one thing nothing on the network can see: an empty
slot is indistinguishable from a card routed to the board, because both report
size 0. So the preflight routes the card here and reads its size, and it *waits*
for it — the mux switching and the block device being usable are about a second
apart, and reading once calls a card that is sitting right there an empty slot.

To settle it by hand:

```sh
labgrid-client -p "$LG_PLACE" power off
labgrid-client -p "$LG_PLACE" sd-mux host
# then on the bench host, after a second or two: a still-zero size means empty
cat /sys/block/sdb/size
labgrid-client -p "$LG_PLACE" sd-mux dut
```

## Prerequisites

### On your machine

`nix develop` (or `direnv allow`) puts `pytest`, `labgrid-client` and the rest on
PATH. Nothing hardware-side is needed locally — no `usbsdmux`, no serial device,
no udev rules.

Two environment variables, both defaulted by the justfile, which is the only
place they are defined:

| | |
| --- | --- |
| `LG_COORDINATOR` | `host:port` of the coordinator |
| `LG_PLACE` | the place to acquire |

And **non-interactive ssh to the bench host**, as the user that owns the devices
there. This is the prerequisite that bites, because labgrid always opens its own
`ControlMaster` with `-o PasswordAuthentication=no`, so it authenticates cold on
every run and a pre-existing multiplexed socket of yours does not help it.

A key that cannot sign unattended is worse than no key. A hardware-backed key
that is unplugged, or a stale `IdentityFile` that fails with `invalid format`,
counts as a *failed authentication* — and OpenSSH's `PerSourcePenalties` will
then drop every further connection from your address for an hour
(`srclimit_penalise: ... active penalty of 3600.000 seconds`), which presents as
`kex_exchange_identification: read: Connection reset by peer` and looks nothing
like a key problem. Give the bench host its own key and keep the broken ones out
of its way:

```
Host bench
  IdentityFile ~/.ssh/id_ed25519_bench
  IdentitiesOnly yes
```

`IdentitiesOnly` is the half that matters: without it ssh still offers every
other key first, and one that cannot sign is enough to trip the penalty.

### On the bench host

Handled by its NixOS module, listed here because the knowledge is hard-won. The
mux needs the `sg` kernel module (its control interface is a SCSI generic device,
`CONFIG_CHR_DEV_SG=m`) and permissions on *both* of its device nodes —
`usbsdmux` sends SCSI commands to the control node, and labgrid's
`USBStorageDriver` dd's the image to the block node, neither as root:

```nix
{ pkgs, ... }:
{
  boot.kernelModules = [ "sg" ];
  environment.systemPackages = [ pkgs.usbsdmux ];
  # Creates the /dev/usb-sd-mux/id-<serial> symlink and does a `kmod load sg`.
  services.udev.packages = [
    pkgs.usbsdmux
    (pkgs.writeTextFile {
      name = "labgrid-bench-udev-rules";
      destination = "/etc/udev/rules.d/71-labgrid-bench.rules";
      text = ''
        SUBSYSTEM=="scsi_generic", ATTRS{manufacturer}=="Linux Automation GmbH", ATTRS{product}=="usb-sd-mux*", TAG+="uaccess", GROUP="plugdev", MODE="0660"
        SUBSYSTEM=="block", ATTRS{manufacturer}=="Linux Automation GmbH", ATTRS{product}=="usb-sd-mux*", TAG+="uaccess", GROUP="plugdev", MODE="0660"
      '';
    })
  ];
  users.groups.plugdev = { };
  users.users.<you>.extraGroups = [ "plugdev" ];
}
```

**The filename is the whole trick, so do not move these into
`services.udev.extraRules`.** systemd applies `uaccess` in
`73-seat-late.rules`:

```
TAG=="uaccess|xaccess-*", ENV{MAJOR}!="", RUN{builtin}+="uaccess"
```

It *tests* the tag at priority 73, and udev sorts rule files by name across all of
its directories — so anything setting the tag later is never seen and grants
nothing at all. That is true of both obvious places to put it: `pkgs.usbsdmux`
ships its rules as `99-usbsdmux.rules`, and `services.udev.extraRules` lands in
`99-local.rules`. Hence an explicit `71-`. (Which also means the comment in
nixpkgs' usbsdmux derivation — *"the udev rule already has `TAG+="uaccess"`, which
is sufficient"* — does not hold for the file as installed.)

`GROUP`/`MODE` are there as well because `uaccess` only grants to whoever holds
the active local seat, which a headless bench host never does. Group membership
covers that, and unlike the ACL it only takes effect on the next fresh login.
Both the exporter's user and the user your ssh lands as need it: the exporter
discovers the mux, and the `dd` and `usbsdmux` calls run as *you*.

Without the `sg` module the mux reports as unavailable with a null
`control_path` — labgrid finds it over udev but never finds a control interface
to switch it with. `just hw-status` shows the `avail` flag; by hand on the bench
host:

```sh
usbsdmux /dev/sg1 get           # dut | host
usbsdmux /dev/sg1 host          # card to the bench host...
cat /sys/block/sdb/size         # ...and it should now be non-zero
usbsdmux /dev/sg1 dut
getfacl /dev/sg1 /dev/sdb       # the ACL the 71- rules grant
```

Address the mux by its real `/dev/sgN` node, not the
`/dev/usb-sd-mux/id-<serial>` symlink. Two reasons, both learned the hard way:
`usbsdmux` takes the *basename* of whatever you hand it and reads
`/sys/class/scsi_generic/<basename>/device/model`, so the symlink only works
while it resolves; and the rule creating it is `ACTION=="add"`-only, so any
`change` event — `udevadm trigger` sends those, and so does switching the mux —
makes it disappear until the device is re-added. The harness never touches it:
labgrid discovers `control_path` by walking the USB device's children, and the
`71-` rules above carry no `ACTION` match, so the permissions are reapplied on
every event.

The exporter also needs `ser2net` on its PATH to export a serial port, and
`rsync` plus `dd` for the image. It does *not* need `python3`: that is only for
labgrid's remote agent, which `write_files` uses and nothing here calls.

## Getting a shell on the board

The release images have no root password and no sshd, so a serial console stops at
a login prompt nothing can answer. `modules/dev.nix` therefore sets
`dashboardAssistant.debug.rootHashedPassword` — root password `dashboard` on the
console only, for the `*-dev` images only. sshd keeps `PasswordAuthentication`
off, so this is not a remote-root path; `modules/core/debug.nix` gates both
affordances separately. A release image still evaluates to no password at all.

### Which UART

The console is on **`ttyAMA10`**, the Pi 5's dedicated debug UART behind the 3-pin
connector — not `ttyAMA0`. `modules/hardware/rpi5.nix` adds the kernel param;
without it the transcript records the boot ROM, the RP1 firmware, U-Boot and
extlinux, then stops dead at `Starting kernel ...` and never reaches a login
prompt, because an explicit `console=` on the cmdline overrides the device tree's
`stdout-path`. The device tree settles it:

```
uart10      = /soc@107c000000/serial@7d001000   <- 3-pin debug connector (pl011)
uart0       = /axi/pcie@.../rp1/serial@30000    <- GPIO 14/15
console     = ...serial@7d001000
stdout-path = "serial10:115200n8"
```

`ttyAMA0` is the GPIO header's UART, which the sd-image `config.txt` disables on
this board anyway (`[pi5] enable_uart=0`). If you ever need to check this on
another board, the device tree is readable straight out of the image without
mounting anything:

```sh
img=$(ls result-rpi5-dev/*.raw)
mcopy -i "$img@@$((16384*512))" ::bcm2712-rpi-5-b.dtb /tmp/pi5.dtb
dtc -I dtb -O dts /tmp/pi5.dtb | sed -n '/aliases {/,/};/p'
```

### The prompt

`modules/dev.nix` also forces a plain `PS1='\u@\h:\w\$ '` and turns readline's
bracketed paste off, so the prompt arrives as bare
`root@dashboard-assistant-a1b2c3:~# ` with no escape sequences in it. That is not
cosmetic — it is what makes the harness work at all.

NixOS' stock prompt wraps itself in a colour code and an xterm title escape, and
readline brackets the whole thing with paste markers, so what actually comes down
the wire is:

```
ESC[?2004h ESC[1;31m [ ESC]0;root@host: ~BEL root@host:~]# ESC[0m
```

`ShellDriver` matches command output with patterns shaped like
`{marker}\s+{prompt}` — it assumes the prompt follows plain *whitespace*. It
cannot match across those escapes, so **no regex for the prompt alone can fix
this**. The symptom is nasty precisely because it looks like it nearly worked:
the login genuinely succeeds, and then ShellDriver sits pressing Enter at a live
root shell until `login_timeout` expires. If you ever see that, check for escapes
in the transcript before touching the regex.

`just hw-console` shows you the real prompt if it ever changes again.

## Reaching the board over the network, and its browser

The serial console is the channel that survives everything, and it is the one
every assertion above uses. Two of them need more than that: asserting the
**dashboard** is on screen means talking to the kiosk browser, and the browser
does not answer on a UART.

### The bench key

`~/.ssh/id_ed25519_bench` — the same key the prerequisites above give the bench
host — is also declared on **dev images** (`modules/dev.nix`), so the **release
gate** can log into a board with nobody present. The private half lives on the
bench host and in the operator's password manager; it is never in this
repository, and a bench that does not have it skips the tests that need it
rather than failing them.

It is the only key on a dev image that can sign unattended. The two `sk-` keys
beside it are hardware-backed and want a human to touch a token, and **an
unsignable key is worse than no key**: the failed attempt counts as a failed
authentication, so OpenSSH's `PerSourcePenalties` drops every connection from
that address for the next hour. An automated run holding only those keys locks
itself out of the board it came to test. Same trap as the bench host, same fix —
`IdentitiesOnly yes`.

**Release images carry no such key, and no sshd at all.** That is not a
convention anyone has to remember: `nix build
.#checks.x86_64-linux.release-has-no-unattended-access` fails if a release image
ever picks one up, along with the root password and the loopback binding below.

### The debugging port is tunnelled, never exposed

Chromium's CDP port (9222) binds to loopback on **every** image, release and dev
alike, and it has to stay that way. It is unauthenticated and already runs with
`--remote-allow-origins=*`, so a device that published it would hand remote code
execution to anything on the same network — a far larger affordance than the
documented console password next to it, and one that would ship on every dev
image rather than sitting behind a board's UART pins.

So nothing on the board is opened. The gate forwards the port over ssh instead:

```sh
ssh -N -L 9222:127.0.0.1:9222 root@<device>     # what kiosk.py does for you
```

and the browser automation attaches to `http://127.0.0.1:9222` on the bench host.
`just qemu-ssh` does the same thing for the QEMU target, which is what makes
`just inject-token` and `just cdp-eval` work.

### Playwright and Chromium are a married pair

`test_journey.py` drives the kiosk with Playwright over that tunnel. Playwright
speaks a CDP dialect that tracks the Chromium it was released against, so the
client and the browser have to move together.

Here they cannot drift: **both come out of the one pinned nixpkgs**
(`docs/adr/0008`). `ps.playwright` in the dev shell and the `chromium` in
`modules/core/kiosk.nix` are resolved from the same `flake.lock` entry, so
`nix flake update nixpkgs-unstable` bumps the pair in a single commit. If you
ever take Playwright from somewhere else — a pip install, a container image —
you have reintroduced the drift this paragraph exists to prevent, and the
symptom is a protocol error that reads like a broken page.

## Layout

| File | |
| --- | --- |
| `bench.yaml` | labgrid environment: the place, the driver stack, credentials, timeouts |
| `qemu-x86.yaml` | labgrid environment for the x86_64 target: QEMU, OVMF, the scratch disk, `board: x86_64` |
| `strategy.py` | `off` → `flashed` → `booted` → `shell` for both targets: `DashboardAssistantStrategy` on the bench, `QEMUStrategy` under QEMU. Plus `reboot()`, a warm reboot in place for across-a-boot assertions |
| `bench.py` | paths, image discovery and the plug's meter, shared by `conftest.py` and `flash.py` |
| `capability.py` | what this bench can do, derived from the place's resources, the board, and what answers on the network — never from a flag |
| `bench_ha.py` | the **Bench Home Assistant**: finding it, resetting it, and driving its websocket and config-flow APIs |
| `device.py` | parsers for what the board says about itself over the console — addresses, Wi-Fi association, persisted state |
| `kiosk.py` | the ssh tunnel to the kiosk browser's loopback debugging port, and the verdict on what is on screen |
| `candidate.py` | which closure a **candidate** would install, and whether the board can fetch it rather than compile it |
| `preflight.py` | `just hw-preflight` — is the bench healthy, reported as a bench fault (exit 2) rather than a test failure |
| `test_capability.py`, `test_preflight.py`, `test_bench.py`, `test_bench_ha.py`, `test_device.py`, `test_kiosk.py`, `test_candidate.py` | unit tests for the modules above; need no bench, no board and no network |
| `conftest.py` | option defaults and the `shell` / `console_log` / `image` / `plug` / `bench_home_assistant` / `paired` / `gate_key` / `candidate_closure` fixtures |
| `test_first_boot.py` | the assertions about a device on its own, the Pi's boot chain included — up to and including whether automatic rollback is armed, which has to be asked on the freshly flashed boot and so cannot live in a file that sorts later |
| `test_journey.py` | the assertions about a device and a real Home Assistant: discovery, pairing, a service call, a dashboard on the screen |
| `test_wifi.py` | the assertions about a device on the Bench Wi-Fi with its wire down |
| `test_update.py` | the update phase: today its precondition only, that the candidate's closure is in the cache |
| `with-place.sh` | acquire if nobody holds it, run, release what it acquired — the prelude every `hw-*` recipe shares |
| `flash.py` | `just hw-flash` — transition to `flashed` and stop |
| `logs/` | serial transcripts, cleared at the start of each run (gitignored) |

## Running it

```sh
just hw-preflight                             # is the bench healthy? run this first
just hw-status                                # the place, its resources, who holds it
just hw-test                                  # build if needed, flash, boot, assert
just hw-flash                                 # flash only
just hw-console                               # watch the UART by hand (Ctrl-\ then q)
just hw-power on|off|cycle|get
just hw-acquire / just hw-release             # hold the bench across several runs

pytest labgrid/ -k "uboot or panic" -vvv      # flash + boot + boot-chain only, no login

pytest labgrid/ --lg-initial-state shell      # board is already up: skip the flash
pytest labgrid/ --image path/to/other.img
pytest labgrid/ -vvv                          # -vv info, -vvv console, -vvvv debug

pytest labgrid/test_capability.py labgrid/test_preflight.py   # no bench needed

pytest labgrid/test_journey.py -v             # discovery, pairing, the dashboard
pytest labgrid/test_wifi.py -v                # Wi-Fi only, wire down and back
```

`test_journey.py` and `test_wifi.py` need a **Bench Home Assistant** at
`$BENCH_HA_URL` (defaulted by the justfile) and skip themselves cleanly when
there is none — which is what the x86_64 target below does, since user-mode
networking carries no mDNS. `test_wifi.py` additionally needs the Bench Wi-Fi's
credentials, declared in `secretspec.toml` and never committed:

```sh
secretspec run -- just hw-test
```

They come from whatever provider your machine is configured for — a KeePassXC
database here; `ops/README.md` has the one-time setup. An invocation secretspec
detects as an agent also needs `--reason "<why>"`, which is its audit-log policy
and worth leaving on.

One caveat worth knowing: that passphrase reaches the card over the board's
**serial console**, because that is the only channel to a board that has no
network yet — so it appears in `logs/console_main`. The directory is
gitignored, but the file is real. Do not attach a bench transcript to a public
issue.

An ordinary run needs no `-m` expression. Tests whose hardware is not on this
bench skip themselves — see "Skipping is derived, never selected" below.

Bare `pytest` needs the place acquired (`just hw-acquire`) and
`LG_COORDINATOR`/`LG_PLACE` in the environment; the `just` recipes handle both.

`--lg-initial-state shell` is the one to reach for while writing assertions: a
reflash is ~4 GiB of `dd` plus a first boot that resizes the filesystem, and none
of that changes between two edits of a test. Acquire the place first and it stays
yours across runs — `with-place.sh` notices and leaves it held.

`acquire` is not idempotent, which is why that wrapper exists at all: acquiring a
place you already hold is an error, so a recipe that unconditionally acquired
would break the iterate-on-assertions workflow above.

### The x86_64 target

The same suite, against the real x86_64 image under QEMU:

```sh
just qemu-test                                       # build if needed, boot, assert
pytest labgrid/ --lg-env labgrid/qemu-x86.yaml -v    # the same thing by hand
```

Not a convenience. The bench has one Raspberry Pi 5 in it and a second board is
a purchase, but a UEFI firmware, a GPT partition table, a real EFI system
partition, a btrfs root and first-boot growth are not — so everything in
`test_first_boot.py` that is not specifically about the Pi runs here too. The
four assertions that *are* about the Pi (the GPU firmware chainloading U-Boot,
U-Boot's EFI bootmanager, the firmware-merged device tree, VideoCore's render
node) carry a `board` marker and skip themselves.

There is no place to acquire and no coordinator, so it runs anywhere the dev
shell does — including alongside a bench run.

Three things about it are worth knowing before trusting a green run:

- **It cannot do discovery or pairing.** User-mode networking carries no mDNS,
  and Home Assistant opens connections *to* a device
  ([ADR 0002](../docs/adr/0002-home-assistant-talks-to-devices-over-https-not-mqtt.md)),
  so neither direction works behind a NAT. The device API is reachable on
  `localhost:18081` and nothing else is. Those assertions stay on the bench
  until this target grows a tap interface.
- **It has no screen.** `display: none` means no graphics device, so no DRM
  connector, so the kiosk tests skip themselves rather than failing against a
  framebuffer Chromium cannot render on. That is the honest answer, not a
  workaround — but it does mean the kiosk is only ever exercised on the bench.
- **The disk is a copy, grown.** The image comes out of the read-only Nix store
  and QEMU writes to its disk in place, so `QEMUStrategy`'s `flashed` state
  copies it to `labgrid/.qemu-disk.raw` and grows it to 8 GiB — the dd
  equivalent. Grown because a disk the size of the image leaves first-boot
  growth nothing to do, and `test_root_filesystem_grew` would pass without
  anything having grown. It is replaced on every run, so no test can pass
  against state it did not create.

The x86 image gets its serial console from `modules/dev.nix`, dev images only —
unlike the Pi, which has one unconditionally. Without `console=ttyS0` the kernel
writes to nothing a harness can read, and a boot that works perfectly says
absolutely nothing. Same failure mode as the Pi's wrong-UART problem below, same
cause: no console, no evidence.

### The candidate has to be in the cache

An update phase does not fail when a **candidate**'s closure is missing from the
cache. It compiles a system on a Raspberry Pi — the `linux-rpi` kernel is on no
public cache — and a **release gate** that takes a night is a release gate
nobody runs. So before any update assertion runs, the board is asked whether it
could fetch the candidate at all:

```sh
BENCH_CANDIDATE=v1.2.0 just hw-test          # gate a candidate
just hw-test                                 # gating nothing: the check skips
```

`BENCH_CANDIDATE` is deliberately **not** defaulted in the `justfile`, unlike
`LG_PLACE` and `BENCH_HA_URL`. Unset has to mean "this run is gating no
release", because a default would quietly gate whichever tag someone wrote down
months ago.

The check is split across the two machines, and the split is the point:

| Step | Where | Why there |
| --- | --- | --- |
| resolve the candidate's closure to a store path | the machine running the suite | evaluation is pure, so the path is the same anywhere — on the board it would be a full nixpkgs evaluation driven over a serial line |
| ask whether that path can be fetched | **the board** | what a device can fetch is decided by *its* substituters and *its* trusted keys (`modules/core/binary-cache.nix`). A bench host with a developer's `nix.conf` answers a different question |

The bar is `nix-store --realise --dry-run` reporting nothing to build at all,
not "mostly cached". A closure that is 99% fetched and 1% compiled is still a
kernel build on a Pi.

Two details of nix's behaviour the check has to work around, both measured
rather than remembered — the captured outputs are in `test_candidate.py`:

- The verdict goes to **stderr** and the exit status is `0` whichever answer it
  is. A command reading only stdout sees every answer as the empty one, and the
  empty one means "already in the local store" — the single verdict that lets
  the phase run.
- A cache miss is remembered for `narinfo-cache-negative-ttl`, an hour by
  default. A candidate checked while that workflow was still pushing would stay
  "missing" long after it had arrived, so the check asks the cache rather than
  nix's memory of it.

#### Who pushes a candidate, and when

[`boards.yml`](../.github/workflows/boards.yml), for every board. It calls
[`board.yml`](../.github/workflows/board.yml) once per board, whose `closure`
job builds that board's system closure on a runner of its own architecture and
pushes it to Attic, on every `v*` tag — and on a push to `main`, which warms
the cache without producing a candidate.

Nothing local pushes: a developer's `just build-rpi5` pulls from the cache and
never fills it, and the push token lives only in CI.

So a `v*` tag produces a candidate whose closures are substitutable once that
workflow is green, and this check's job is to say so before the phase starts
rather than after ninety minutes of compiling.

**Every board, x86_64 included, and the reason is narrower than cache
coverage.** `cache.nixos.org` does serve the pinned `nixos-unstable` revision
every board builds from ([ADR 0008](../docs/adr/0008-every-board-builds-from-pinned-nixos-unstable.md)),
so most of an x86 closure substitutes from upstream. What never substitutes is
a *system closure*: the daemon, `sendspin-go`, `vboard`, the kiosk
configuration and the toplevel itself are this repository's own output, and no
public cache has ever held them. The Pi's `linux-rpi` kernel — hours under
emulation, on no public cache at all — is a difference of degree, not of kind.

This was not always true. Until the two flows were unified (issue #55) the
aarch64 closures were built on a native arm64 runner and pushed, while the
x86_64 image was built and published with no closure push at all — so an x86
candidate could not be fetched by a device and its update phase could not be
gated. This check is what surfaced it.

### Skipping is derived, never selected

A test skips because the hardware it needs is not here, and nothing you type can
tell it otherwise. Two sources, both the hardware itself:

| What | Where it comes from |
| --- | --- |
| the plug, the card mux, the console | the resources the place publishes, so a bench without one simply has none (`capability.missing_resource`) |
| a display | the board's own DRM connectors, because a panel is not a labgrid resource and nothing on the network can see one (`capability.missing_display`) |

The `needs_display` marker still exists, but it only *declares* the requirement;
the `_needs_display` fixture decides, by asking the board whether any connector
reads `connected`. So a headless bench needs no `-m "not needs_display"`, and
the kiosk tests run by themselves as soon as a panel is plugged in (the official
Touch Display 2 is what this bench uses; an HDMI dummy plug also works).

**This is not a tidiness exercise.** The browser-cache and screenshot tests need
a screen because greetd/sway/Chromium crash-loop without one, and a strict
"nothing in the failed state" check fails for reasons unrelated to the code. But
`test_no_failed_units` once carried that same marker — and because this README
recommended `-m "not needs_display"` for a headless bench, a marker meaning
"needs a screen" quietly decided whether a *storage* bug was visible. Devices
shipped with a quarter of their storage. See "What this bench found" below. A
flag that can hide a bug class is worse than no flag.

## What this bench found

Kept as a record of what hardware testing bought, and as context for the tests
that now guard each one.

**Seed provisioning was broken on both Pi images** — the one that reached users.
`website/content/flash/seed.md` said *"The /boot partition is FAT and readable
on any computer"*. True on x86, where `/boot` is the ESP. On the Pi, `/boot` was a
directory on the btrfs root, and the partition a user can actually write to was
`FIRMWARE` — declared `noauto`, never mounted, with no mount point. So the file
landed where the importer never looked, `ConditionPathExists` skipped the unit,
and **nothing was logged**. `configimport.nix` now falls back to mounting the FAT
partition read-only, and `test_seed_file_from_flashed_partition` performs the
user's action on the real artifact.

!!! note "Since fixed at the root"
    The whole class of bug above came from the Pi and x86 images having
    different layouts. They do not any more: both are built by disko from
    `modules/hardware/disk-layout.nix`, `/boot` *is* the FAT EFI system
    partition on every target, and `configimport.nix` has one code path with no
    partition label to drift. The tests below are kept pointed at the real
    artifact anyway — that is what caught this — but the label-mismatch and
    never-mounted-partition failure modes no longer exist to catch.

Neither VM test could have caught it. `tests/first-boot.nix` does `mkdir -p /boot`
and says so outright — "what is under test is the import, not where the partition
came from" — which is fair for a node with no disk layout, and is exactly the
blind spot.

Three follow-ups came out of that one, all guarded here now. The label is no
longer a literal in `configimport.nix` — it comes from
`sdImage.firmwarePartitionName` via
`dashboard.configImport.firmwarePartitionLabel`, so the image and the importer
cannot drift apart again. The partition explains itself: the image stages a
`README.txt` and a commented `dashboard-assistant.yaml.example` onto it, which
`test_firmware_dropzone_files` asserts on the real artifact. And seeding is no
longer one-shot: the importer records a sha256 of what it applied and re-imports
whenever the file changes, so editing the YAML on the card and rebooting
re-provisions a device in place. `test_seed_file_reimported_after_edit` proves
that across a real reboot (hence `strategy.reboot()`), and
`test_kiosk_not_restarted_by_unchanged_seed` proves the other half — that a boot
which imports nothing does not relaunch the session. The VM test cannot make
that last one: greetd is disabled there.

**growpart raced the /tmp mount, and devices shipped with a quarter of their
storage.** Two stock NixOS options, both deliberate here, with no ordering
relationship between them: `boot.growPartition` (`rpi-disk-image.nix`) and
`boot.tmp.useTmpfs` (`flash-wear.nix`). nixpkgs' `growpart.service` runs with
`DefaultDependencies=false` and `After=-.mount`, so it starts while `/` is the
only thing mounted, and `mktemp -d` puts its scratch directory on the root
filesystem. `tmp.mount` then lands on top of it mid-run. Measured on the bench:

```
growpart ExecMainStart     5.615 s
tmp.mount activated        6.639 s     <- here
growpart ExecMainExit      9.760 s
```

```
.growpart-wrapped: line 714: /tmp/.growpart-wrapped.LKQ3k7/pt_update.err: No such file or directory
failed [pt_update:1] pt_update /dev/mmcblk0 2
FAILED: pt_resize failed
```

Exit 2, and the unit's `SuccessExitStatus=0 1` does not cover it, so the unit
fails and `systemd-growfs-root.service` — ordered after it — never finishes the
job. The device boots with a **3.5 GB root on a 14.8 GB card**, `degraded`.

What makes it nasty is how well it hides. On the *next* boot there is nothing
left to grow, growpart exits 1 for `NOCHANGE`, that *is* whitelisted, and the
unit goes green — so anyone who reboots before looking sees a healthy system.
And the damage is not deterministic: the first run of this suite hit the same
failure but the filesystem grew anyway, which is why `test_root_filesystem_grew`
passed that time. It now measures against the medium rather than the image, so a
partial growth cannot pass it, and `test_growpart_succeeded` names the unit so
the next regression reports a cause rather than a symptom.

Fixed by pointing the unit's `TMPDIR` at `/run`, a tmpfs mounted in the initrd
and never mounted over (`disk-layout.nix`). The upstream fix belongs in nixpkgs'
`grow-partition.nix`.

Two things about the *tests* came out of this, both worth more than the bug.
`test_no_failed_units` was the only thing that caught it — and it was marked
`needs_display`, so every headless run (`-m "not needs_display"`, which this
README recommends) skipped it. A marker meaning "needs a screen" had been
quietly deciding whether a storage bug was visible. The check is now split: the
general one is unmarked and excludes only the kiosk units by name, and
`test_kiosk_units_not_failed` carries the marker. The other: no VM test can see
any of this, because there is nothing to grow in a VM — which is the same blind
spot, in the same place, as the seed-file bug above.

**The kernel console was on the wrong UART.** The Pi 5's debug connector is
`ttyAMA10`; the sd-image supplies `ttyS0`/`ttyAMA0`/`tty0`. The board booted
perfectly and said nothing. See "Which UART" above.

**NixOS' prompt cannot be matched by a regex.** Login succeeded and then every
command timed out. See "The prompt" above.

**udev `uaccess` at priority 99 does nothing.** `73-seat-late.rules` reads the tag
at 73, so both `services.udev.extraRules` and the `usbsdmux` package's own rules
are too late to grant anything. See "On the bench host".

**One unsignable ssh key locks you out of the whole bench for an hour.** Not a
labgrid problem and not a key problem, as far as the error message goes. See
"On your machine".

## Keep the probe off the mux's USB controller — where you can

**A Debug Probe and a USB-SD-Mux sharing a root hub can cost you the serial
console.** They did on the first bench — both on `usb1` — and the symptom was not
a USB error but a *lossy serial console*: a measured **34% of Pi → host bytes went
missing**, in clean deletions rather than garbled characters. `/proc/cmdline` read
back as `console=ttyAMA1115200n8` (the `0,` deleted) and `lsm=landlock,yama,bp`.
Echo a known 36-character line 40 times and exactly one arrived intact.

What makes this worth writing down is how it presents. The boot-chain tests pass,
the board boots fine, and the failure lands in `ShellDriver.on_activate`:
`_await_login` needs ~15 newlines to get past `login: `, then `_inject_run` times
out after 30 s because the prompt arrives as
`root@dashboard-assistant-d7bbb4:` with `~# ` missing. That looks exactly like
the prompt-escapes problem above, and it is not — relaxing the prompt regex fixes
nothing, because the next burst loses a different number of bytes. `never_retry`
then marks the strategy broken, so all 13 shell-dependent tests report as
*skipped* and the summary reads "3 passed, 13 skipped, 1 error", which does not
look like a hardware fault at all.

Moving the probe to a separate controller took the loss to 0% and the suite from
3 passed to 17. The mechanism is bandwidth: reaching `flashed` dd's ~4 GiB
through the mux, and on a shared controller that starves the probe's CDC-ACM
endpoint until its UART ring buffer overruns. The loss is one-directional — host
→ Pi stays clean, so commands still arrive and only the replies are shredded.

Check the topology before suspecting anything in software, on the bench host:

```sh
readlink -f /sys/class/tty/ttyACM0/device        # probe   -> .../usb1/1-1/...
readlink -f /sys/block/sdb/device                # SD-Mux  -> .../usb1/1-4/...
```

**On a host with a single xHCI controller you cannot separate them**, and moving
ports will not help: the mux enumerates at high speed, so it lands on the USB 2.0
root hub whatever the port looks like, and the probe is a full-speed device that
does the same. Measure instead of assuming — with the board at a shell:

```sh
# 40 intact lines = healthy; anything less means check the USB topology first.
# $LABGRID_PYTHON, not python3 — see Gotchas below for why.
"$LABGRID_PYTHON" -c '
import serial,time
S="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
s=serial.Serial("/dev/ttyACM0",115200,timeout=0.2); time.sleep(0.3)
s.reset_input_buffer(); s.write(b"for i in $(seq 1 40); do echo "+S.encode()+b"; done\r")
b=b""; t=time.time()
while time.time()-t<8: b+=s.read(65536)
print(sum(1 for l in b.decode("utf-8","replace").split("\n") if l.strip("\r")==S), "/40 intact")'
```

Two things make this less likely to bite than it did: the `dd` finishes and the
storage driver is deactivated before the console is ever activated (`flashed` →
`booted` in `strategy.py`), and the console now arrives over ser2net rather than
from a local port. If it does bite, the mitigation is to keep the console closed
while the image is written.

If the port stops accepting writes entirely — reads still work, but
`printf "\r" > /dev/ttyACM0` blocks forever and `tcdrain` never returns — the
probe's CDC-ACM write endpoint is wedged, which killing a harness process
mid-operation can do. Flow control is not the cause (`stty -a` already shows
`-ixon -crtscts`). Replug it, or reset it without touching the cable:

```sh
sudo sh -c 'echo 0 > /sys/bus/usb/devices/1-1/authorized; echo 1 > /sys/bus/usb/devices/1-1/authorized'
```

## Gotchas

- `python3` inside `nix develop` is **not** the interpreter that has labgrid —
  another dependency (zensical) puts a bare python earlier on `PATH`. Use the
  `pytest` wrapper, or `$LABGRID_PYTHON` for anything that needs to
  `import labgrid` directly. `python3 -c "import labgrid"` failing with
  `No module named labgrid.util` is this, not a broken install.
- `write_image` does not decompress. disko emits a single uncompressed `.raw`,
  which is what the harness wants; pointing `--image` at a compressed release
  artifact (`.raw.zst`, as published to R2) would dd the compressed bytes onto
  the card.
- Run from the repo root: image discovery is relative to it.
- The image crosses the network once per build, not once per flash —
  `ManagedFile` keys the copy on the file's hash under `~/.cache` on the bench
  host, so reflashing the same image skips the transfer.
