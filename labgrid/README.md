# Hardware bench

Automated first-boot tests on a real Raspberry Pi 5, driven by
[labgrid](https://labgrid.readthedocs.io/).

```
just build-rpi5-dev   # build the image
just hw-test          # flash it, boot the board, assert
```

`tests/first-boot.nix` already covers everything a VM can reach, and CI runs it on
every push. What it cannot reach is the part of this OS that only exists on
hardware: the Pi's boot chain (GPU firmware → U-Boot → extlinux → Linux), the
btrfs root on a real SD card, first-boot growfs, the FAT firmware partition, and
the kiosk session on a real GPU. That is what this directory is for, and
`test_first_boot.py` deliberately repeats the VM test's assertions alongside the
hardware-only ones.

## The bench

```
                 ┌──────────────────────┐
                 │  this machine        │
                 │                      │
   USB ──────────┤ usbsdmux + dd        │
   (mux control  │                      │
    + card)      │  pytest / labgrid    │
                 │                      │
   USB ──────────┤ serial console       │
   (Debug Probe) └──────────┬───────────┘
                            │ HTTP
   ┌────────────┐      ┌────┴─────────┐
   │ USB-SD-Mux │      │ ESPHome plug │
   │  SD card   │      │  (mains)     │
   └─────┬──────┘      └────┬─────────┘
         │ card              │ power
       ┌─┴───────────────────┴─┐
       │   Raspberry Pi 5      │── UART ── Debug Probe
       └───────────────────────┘
```

| Part | Identity | Where it is configured |
| --- | --- | --- |
| USB-SD-Mux (Linux Automation, FAST) | serial `00048.01623` | `bench.yaml` |
| Raspberry Pi Debug Probe (UART = `if01`) | serial `E665B8388780722E` | `bench.yaml` |
| Athom Plug V3 running ESPHome | `http://192.168.178.245`, switch `switch` | `bench-power.sh` (`DA_PLUG_URL`, `DA_PLUG_SWITCH`) |

An SD card has to be sitting in the mux. Nothing checks for one up front; you get
a "timeout while waiting for medium" from the write step instead.

## Host prerequisites

The mux needs two things this repo cannot provide, because they are host
configuration: the `sg` kernel module (its control interface is a SCSI generic
device, and `CONFIG_CHR_DEV_SG=m`) and permissions on *both* of its device nodes —
`usbsdmux` sends SCSI commands to the control node, and labgrid's
`USBStorageDriver` dd's the image to the block node, neither as root. On this
bench they live in `~/forgejo/nixos/modules/nixos/labgrid-bench.nix`. The
equivalent for any NixOS host:

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
the active local seat: it covers running the tests from your desktop session, but
a headless or ssh-driven run gets nothing from it. Group membership covers that,
and unlike the ACL it only takes effect on your next fresh login.

Without the `sg` module labgrid reports the mux as unavailable with a null
`control_path` — it finds the mux over udev but never finds a control interface to
switch it with. `just hw-status` distinguishes all of these; by hand:

```sh
usbsdmux /dev/sg2 get           # dut | host
usbsdmux /dev/sg2 host          # card to this machine...
cat /sys/block/sdc/size         # ...and it should now be non-zero
usbsdmux /dev/sg2 dut
getfacl /dev/sg2 /dev/sdc       # the ACL the 71- rules grant
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
img=$(ls result-rpi5-dev/sd-image/*.img)
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

## Layout

| File | |
| --- | --- |
| `bench.yaml` | labgrid environment: resources, drivers, credentials, timeouts |
| `strategy.py` | `off` → `flashed` → `booted` → `shell`; the flash-and-boot dance, once. Plus `reboot()`, a warm reboot in place for across-a-boot assertions |
| `bench.py` | paths and image discovery, shared by `conftest.py` and `flash.py` |
| `conftest.py` | option defaults and the `shell` / `console_log` / `image` / `plug` fixtures |
| `test_first_boot.py` | the assertions |
| `flash.py` | `just hw-flash` — transition to `flashed` and stop |
| `status.py` | `just hw-status` — read-only report on every link in the chain |
| `bench-power.sh` | ESPHome plug: `on` / `off` / `cycle` / `state` / `draw` |
| `labgrid-config.yaml` | exporter config — unused, see below |
| `logs/` | serial transcripts, cleared at the start of each run (gitignored) |

## Running it

```sh
just hw-status                                # is the bench wired up? (read-only)
just hw-test                                  # build if needed, flash, boot, assert
just hw-flash                                 # flash only
just hw-console                               # watch the UART by hand
just hw-power on|off|cycle|state|draw

pytest labgrid/ -k "uboot or panic" -vvv      # flash + boot + boot-chain only, no login

pytest labgrid/ --lg-initial-state shell      # board is already up: skip the flash
pytest labgrid/ -m "not needs_display"        # headless bench, see below
pytest labgrid/ --image path/to/other.img
pytest labgrid/ -vvv                          # -vv info, -vvv console, -vvvv debug
```

`--lg-initial-state shell` is the one to reach for while writing assertions: a
reflash is ~4 GiB of `dd` plus a first boot that resizes the filesystem, and none
of that changes between two edits of a test.

### Headless benches

`test_no_failed_units` is marked `needs_display`. On real hardware the kiosk
session actually runs, and greetd/sway/Chromium crash-loop with nothing plugged
into HDMI — which fails a strict "nothing in the failed state" check for reasons
unrelated to the code under test. Attach a display or an HDMI dummy plug, or run
with `-m "not needs_display"`.

## What this bench found

Kept as a record of what hardware testing bought, and as context for the tests
that now guard each one.

**Seed provisioning was broken on both Pi images** — the one that reached users.
`docs/flash/seed.md` said *"The /boot partition is FAT and readable on any
computer"*. True on x86, where `/boot` is the ESP. On the Pi, `/boot` is a
directory on the btrfs root, and the partition a user can actually write to is
`FIRMWARE` — declared `noauto`, never mounted, with no mount point. So the file
landed where the importer never looked, `ConditionPathExists` skipped the unit,
and **nothing was logged**. `configimport.nix` now falls back to mounting
`FIRMWARE` read-only, and `test_seed_file_from_flashed_partition` performs the
literal user action through the SD-Mux.

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

**The kernel console was on the wrong UART.** The Pi 5's debug connector is
`ttyAMA10`; the sd-image supplies `ttyS0`/`ttyAMA0`/`tty0`. The board booted
perfectly and said nothing. See "Which UART" above.

**NixOS' prompt cannot be matched by a regex.** Login succeeded and then every
command timed out. See "The prompt" above.

**udev `uaccess` at priority 99 does nothing.** `73-seat-late.rules` reads the tag
at 73, so both `services.udev.extraRules` and the `usbsdmux` package's own rules
are too late to grant anything. See "Host prerequisites".

## Why there is no coordinator

`labgrid-config.yaml` describes the same two resources for labgrid's
exporter/coordinator, and the tests do not use it. Everything here is on one
machine, and going through the coordinator would make that worse rather than
better: `NetworkResource.command_prefix` always routes through ssh, so `dd` and
`usbsdmux` would run over ssh-to-self, and `ManagedFile.sync_to_resource` rsyncs
the image into `~/.cache` on the "remote" host — a 4 GiB copy from this disk to
this disk, every flash. `bench.yaml` declares the resources directly instead.

The exporter config is kept for the day a second board, another machine, or a CI
runner needs to reach these over the network. Note that `places.yaml` and
`resources.yaml` are coordinator *runtime state*, written into whatever directory
it was started in; both are gitignored.

## Keep the probe off the mux's USB controller

**The Debug Probe and the USB-SD-Mux must not share a root hub.** They did at
first — both on `usb1` — and the symptom was not a USB error but a *lossy serial
console*: a measured **34% of Pi -> host bytes went missing**, in clean deletions
rather than garbled characters. `/proc/cmdline` read back as
`console=ttyAMA1115200n8` (the `0,` deleted) and `lsm=landlock,yama,bp`. Echo a
known 36-character line 40 times and exactly one arrived intact.

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

Check the topology before suspecting anything in software:

```sh
readlink -f /sys/class/tty/ttyACM0/device        # probe   -> .../usb3/3-4/...
readlink -f /sys/block/sdc/device                # SD-Mux  -> .../usb1/1-4/...
```

Different `usbN` means different controllers. Moving the probe to a rear
mainboard port took the loss to 0% and the suite from 3 passed to 17. The reason
is bandwidth: reaching `flashed` dd's ~4 GiB through the mux, and on a shared
controller that starves the probe's CDC-ACM endpoint until its UART ring buffer
overruns. Note the loss is one-directional — host -> Pi stays clean, so commands
still arrive and only the replies are shredded.

A quick way to measure it, with the board at a shell:

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

If the port stops accepting writes entirely — reads still work, but
`printf "\r" > /dev/ttyACM0` blocks forever and `tcdrain` never returns — the
probe's CDC-ACM write endpoint is wedged, which killing a harness process
mid-operation can do. Flow control is not the cause (`stty -a` already shows
`-ixon -crtscts`). Replug it, or reset it without touching the cable:

```sh
sudo sh -c 'echo 0 > /sys/bus/usb/devices/3-4/authorized; echo 1 > /sys/bus/usb/devices/3-4/authorized'
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
- Run from the repo root. `bench.yaml` uses labgrid's `$BASE` for the power
  script, so that part is cwd-independent, but image discovery is relative to the
  repo.
