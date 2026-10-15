# Show this help menu (default when `just` is run with no arguments).
help:
  @echo "dashboard-assistant OS — just recipes"
  @echo
  @echo "Build images:"
  @echo "  build-disk-image             Build the release raw disk image (btrfs+zstd)"
  @echo "  build-disk-image-dev         Build the dev raw disk image (SSH + debugging)"
  @echo "  build-rpi4             Build the Raspberry Pi 4 SD-card image (aarch64)"
  @echo "  build-rpi5             Build the Raspberry Pi 5 SD-card image (aarch64)"
  @echo "  build-rpi5-dev         Build the Pi 5 SD-card image with root SSH (dev)"
  @echo "  deploy-rpi5-dev HOST   Push the working tree to a dev Pi over SSH (no reflash)"
  @echo
  @echo "Run / connect (QEMU):"
  @echo "  qemu-run               Boot the built disk image in QEMU"
  @echo "  qemu-ssh               SSH into the VM, tunnelling the daemon (:8080) and CDP (:9222)"
  @echo "  net-check              Hit the networking API from inside the guest"
  @echo
  @echo "Drive the kiosk (needs qemu-ssh running):"
  @echo "  inject-token TOKEN     Log the kiosk into HA by injecting a long-lived token via CDP"
  @echo "  cdp-eval EXPR          Evaluate arbitrary JS in the kiosk page over CDP"
  @echo
  @echo "Hardware bench (labgrid — see labgrid/README.md):"
  @echo "  hw-status              Show the place, its resources and who holds it"
  @echo "  hw-seed --ha-url URL   Provision the bench board from a real seed file"
  @echo "  hw-preflight           Check the bench is healthy before trusting a run"
  @echo "  qemu-test              Run the suite against the x86_64 image under QEMU"
  @echo "  hw-test                Flash the Pi 5 dev image to the bench board and assert first boot"
  @echo "  hw-flash               Flash the bench board and stop there"
  @echo "  hw-console             Watch the bench board's serial console"
  @echo "  hw-power ACTION        on | off | cycle | get on the bench plug"
  @echo "  hw-acquire/hw-release  Hold the bench across several runs"
  @echo
  @echo "Introspect:"
  @echo "  options                List the dashboardAssistant.* NixOS config options"
  @echo
  @echo "R2 images bucket:"
  @echo "  r2-lifecycle-apply     Apply ops/r2-lifecycle.json to the bucket"
  @echo "  r2-lifecycle-show      Print the bucket's current lifecycle policy"
  @echo
  @echo "Run 'just --list' for the raw recipe list."

# The bench is not attached to this machine: it hangs off the bench host, which
# exports it through a labgrid coordinator (see docs/adr/0010). Both of these are
# taken from the environment first, so a second bench needs no edit here — and
# this is the only place the defaults live, which is why labgrid/conftest.py
# refuses to invent its own.
export LG_COORDINATOR := env_var_or_default("LG_COORDINATOR", "bench:20408")
export LG_PLACE := env_var_or_default("LG_PLACE", "raspberrypi5")

# Where the Bench Home Assistant is — the instance a bench device pairs with
# (docs/adr/0012). Same rule as the two above: defaulted here and nowhere else,
# so labgrid/conftest.py can treat "unset" as "this target has no Home
# Assistant" and skip the journey rather than pointing it at someone else's
# instance. The service itself, its pinned version, its fixture and its reset
# unit live in the bench host's configuration, outside this repository.
#
# No token here. It is read off the bench host at /etc/bench-home-assistant/token,
# beside the fixture that minted it, so there is no second copy to drift —
# override with BENCH_HA_TOKEN for a throwaway instance.
export BENCH_HA_URL := env_var_or_default("BENCH_HA_URL", "http://192.168.178.72:8123")

# Build the release installable raw disk image (btrfs+zstd, built by disko). No
# SSH daemon; reconfigure a deployed device only via the USB seed file. dd
# result/dashboard-assistant.raw to the SSD, then boot it from the native SATA port.
[doc('Build the release raw disk image (btrfs+zstd)')]
build-disk-image:
  nix build .#disk-image
  @echo
  @echo "Image: $(readlink -f result)/dashboard-assistant.raw"
  @echo "Flash it (confirm the device first!):"
  @echo "  sudo dd if=$(readlink -f result)/dashboard-assistant.raw of=/dev/disk/by-id/ata-WDC_WDS100T2B0A-00SM50_195206A003DE bs=4M oflag=sync conv=fsync status=progress"

# Build the dev raw disk image — same as build-disk-image plus modules/dev.nix
# (root SSH access and a serial console). For bench/field debugging only; never
# flash this onto a released device.
#
# Its own out-link, so it cannot overwrite the release image's `result` — and so
# `just qemu-test` can find it by path the way the bench finds result-rpi5-dev.
# Two images with the same link is how you spend an afternoon testing the one
# you did not build.
[doc('Build the dev raw disk image (SSH + debugging)')]
build-disk-image-dev:
  nix build .#disk-image-dev --out-link result-x86-dev
  @echo
  @echo "Image: $(readlink -f result-x86-dev)/dashboard-assistant.raw"
  @echo "Flash it (confirm the device first!):"
  @echo "  sudo dd if=$(readlink -f result-x86-dev)/dashboard-assistant.raw of=/dev/disk/by-id/ata-WDC_WDS100T2B0A-00SM50_195206A003DE bs=4M oflag=sync conv=fsync status=progress"

# Build the Raspberry Pi 4 (aarch64) SD-card image. On an x86 host the aarch64
# closure builds via binfmt emulation — but once CI has populated the public
# Attic cache (.github/workflows/cache-rpi.yml), --accept-flake-config lets the
# flake's extra-substituter pull the kernel + system instead of recompiling it,
# so this is a download rather than a slow emulated build. Falls back to building
# if the cache is cold or unreachable. Then flash the image to an SD card.
# Note: the flake substituter is only honoured if you're a trusted Nix user
# (nix.settings.trusted-users on this workstation).
#
# Built by disko from the same layout as the x86 image, so the artifact is a
# single raw GPT image and is flashed exactly like one — no .zst, no sd-image
# subdirectory. The image-builder VM runs natively (see
# dashboardAssistant.diskImage.builderPkgs); only nixos-install's chroot is
# emulated, which needs binfmt plus boot.binfmt.preferStaticEmulators on this
# workstation. The unqualified `.#rpi*-image` attrs resolve to this host's
# packages bucket, which is what picks the right builder VM: cross/binfmt on
# an x86 workstation, fully native on an aarch64 one.
[doc('Build the Raspberry Pi 4 SD-card image (aarch64)')]
build-rpi4:
  nix build .#rpi4-image --accept-flake-config --out-link result-rpi4
  @echo
  @echo "Image: $(readlink -f result-rpi4)/dashboard-assistant-rpi4.raw"
  @echo "Flash it (confirm the device first!):"
  @echo "  sudo dd if=result-rpi4/dashboard-assistant-rpi4.raw of=/dev/sdX bs=4M status=progress conv=fsync"

# Build the Raspberry Pi 5 (aarch64) SD-card image. Same emulated-build /
# binary-cache story as build-rpi4, and the same raw disko artifact.
[doc('Build the Raspberry Pi 5 SD-card image (aarch64)')]
build-rpi5:
  nix build .#rpi5-image --accept-flake-config --out-link result-rpi5
  @echo
  @echo "Image: $(readlink -f result-rpi5)/dashboard-assistant-rpi5.raw"
  @echo "Flash it (confirm the device first!):"
  @echo "  sudo dd if=result-rpi5/dashboard-assistant-rpi5.raw of=/dev/sdX bs=4M status=progress conv=fsync"

# Build the dev flavour of the Pi 5 image: same system plus root SSH (the keys in
# modules/dev.nix). Flash this one when a Pi needs debugging — with sshd up you
# reconfigure it in place with `just deploy-rpi5-dev` instead of pulling the card
# and reflashing for every change. Never ship it: a release image has no sshd.
[doc('Build the Raspberry Pi 5 SD-card image with root SSH (dev/debugging)')]
build-rpi5-dev:
  nix build .#rpi5-image-dev --accept-flake-config --out-link result-rpi5-dev
  @echo
  @echo "Image: $(readlink -f result-rpi5-dev)/dashboard-assistant-rpi5.raw"
  @echo "Flash it (confirm the device first!):"
  @echo "  sudo dd if=result-rpi5-dev/dashboard-assistant-rpi5.raw of=/dev/sdX bs=4M status=progress conv=fsync"
  @echo
  @echo "Then, for every change after that (no reflash):"
  @echo "  just deploy-rpi5-dev root@dashboard-assistant-<mac6>.local"

# Push the current tree to an already-flashed dev Pi and switch it live. Builds
# here (aarch64 under binfmt, mostly from cache) and copies the closure over SSH,
# so the Pi does no compiling. HOST is anything ssh takes: root@<ip>, or
# root@dashboard-assistant-<mac6>.local via mDNS. Use `boot` instead of `switch`
# as the ACTION when a change needs a reboot (kernel, firmware, initrd).
[doc('Deploy the working tree to a dev Pi over SSH (no reflash)')]
deploy-rpi5-dev HOST ACTION="switch":
  nixos-rebuild {{ACTION}} \
    --flake .#dashboard-assistant-rpi5-dev \
    --target-host {{HOST}} \
    --accept-flake-config

# Boot the built disk image (run `just build-disk-image` first). The virtio-net
# NIC gets DHCP from QEMU's user-mode network, so NetworkManager auto-connects
# it — first boot comes up online, showing the add-to-Home-Assistant splash
# (the wired / existing-connection path). Interact with the wizard directly on
# the QEMU display, or drive it from the host via `just qemu-ssh` (see the
# loopback note there).
#
# The image is UEFI-only (C-4: systemd-boot in an EFI system partition), so this
# needs OVMF firmware — $OVMF_FD comes from the dev shell. And it boots a
# *writable copy*: the guest mounts / read-write and the first boot grows the
# filesystem, so booting result/ directly would both fail (read-only store path)
# and make the recipe single-use. Delete .qemu-disk.raw to start from a fresh
# image.
[doc('Boot the built disk image in QEMU')]
qemu-run:
  #!/usr/bin/env bash
  set -euo pipefail
  : "${OVMF_FD:?not set — enter the dev shell with 'nix develop' or 'direnv allow'}"
  raw="$(readlink -f result)/dashboard-assistant.raw"
  [ -f "$raw" ] || { echo "no image at $raw — run 'just build-disk-image' first" >&2; exit 1; }
  if [ ! -f .qemu-disk.raw ]; then
    echo "copying $raw -> .qemu-disk.raw (writable; delete it to reset)"
    install -m 644 "$raw" .qemu-disk.raw
  fi
  exec qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 -smp 2 \
    -machine q35 \
    -bios "$OVMF_FD" \
    -drive file=.qemu-disk.raw,format=raw,if=virtio \
    -device virtio-vga-gl \
    -display gtk,gl=on \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net,netdev=net0 \
    -device virtio-serial-pci \
    -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on \
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0

# SSH into the running VM with the daemon tunnelled to the host. The -L tunnel
# delivers to the guest's *loopback*, which satisfies the wizard's loopback-only
# guard — so while this session is open you can open http://localhost:8080/setup
# in a host browser, or curl the provisioning API. (A raw QEMU port-forward would
# arrive as non-loopback and get 403.) Requires SSH login to be enabled on the
# image — see the note in README/daemon for the test-only credentials snippet.
[doc('SSH into the VM, tunnelling the daemon (:8080) and CDP (:9222)')]
qemu-ssh:
  ssh -p 2222 \
    -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -L 8080:localhost:8080 -L 9222:localhost:9222 root@localhost -vvv

# Exercise the networking API from inside the guest (loopback, so guarded
# endpoints work). Runs over SSH without needing the tunnel session open.
[doc('Hit the networking API from inside the guest')]
net-check:
  ssh -p 2222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    root@localhost 'curl -fsS localhost:8080/api/state; echo; \
    curl -fsS localhost:8080/api/netinfo; echo'
# Log the kiosk into Home Assistant by injecting a long-lived access token
# straight into the page via CDP — no Chrome, no chrome://inspect, no version
# mismatch. Requires `just qemu-ssh` running in another terminal (it tunnels
# :9222). The CDP port is always open on loopback — no option needed.
# Create the token in HA: Profile -> Security -> Long-lived access tokens.
#   just inject-token "eyJhbGciOi..."
[doc('Log the kiosk into HA by injecting a long-lived token via CDP')]
inject-token token:
  #!/usr/bin/env bash
  set -euo pipefail
  ws=$(curl -fsS http://localhost:9222/json \
        | jq -r '[.[] | select(.type=="page")][0].webSocketDebuggerUrl // empty')
  if [ -z "$ws" ]; then
    echo "No inspectable page on :9222 — is 'just qemu-ssh' running and remote debugging on?" >&2
    exit 1
  fi
  # Navigate to the app root, not reload(): hassTokens is consumed by the main
  # app entrypoint, while /auth/authorize (the login screen) ignores it.
  expr='localStorage.setItem("hassTokens", JSON.stringify({access_token:"{{token}}",token_type:"Bearer",expires_in:315360000,expires:Date.now()+315360000000,refresh_token:"",clientId:null,hassUrl:location.origin})); location.replace(location.origin + "/");'
  jq -cn --arg e "$expr" '{id:1,method:"Runtime.evaluate",params:{expression:$e}}' \
    | timeout 5 websocat "$ws" || true
  echo "Token injected — the kiosk should load the dashboard logged in."

# Evaluate arbitrary JS in the kiosk page over CDP and print the raw result.
# Needs `just qemu-ssh` running. Use double quotes inside the expression.
#   just cdp-eval 'location.href'
#   just cdp-eval 'localStorage.getItem("hassTokens")'
[doc('Evaluate arbitrary JS in the kiosk page over CDP')]
cdp-eval expr:
  #!/usr/bin/env bash
  set -euo pipefail
  ws=$(curl -fsS http://localhost:9222/json \
        | jq -r '[.[] | select(.type=="page")][0].webSocketDebuggerUrl // empty')
  if [ -z "$ws" ]; then echo "No inspectable page on :9222" >&2; exit 1; fi
  jq -cn --arg e '{{expr}}' \
    '{id:1,method:"Runtime.evaluate",params:{expression:$e,returnByValue:true}}' \
    | timeout 5 websocat "$ws" || true

# Show the place: every exported resource, whether each is available, and who
# holds it. Read-only, needs no acquire, and safe at any time — the first thing
# to run when a hardware test fails, because it separates "someone else has the
# bench" from "the exporter cannot see the mux" from "the coordinator is down".
#
# It stops short of the card, which nothing on the network can see: an absent
# card is indistinguishable from a card routed to the board. For that, and for
# the plug, go one level down (both need the place held — `just hw-acquire`):
#
#   labgrid-client -p $LG_PLACE sd-mux get     dut | host
#   labgrid-client -p $LG_PLACE power get      is the rail on
#
# and if `sd-mux host` still leaves the mux's block device at size 0 on the bench
# host, the slot is empty.
[doc('Show the place, its resources and who holds it')]
hw-status:
  labgrid-client -p "$LG_PLACE" show

# Run the hardware suite against the x86_64 image under QEMU — the only testing
# that image gets on anything resembling hardware. Same assertions as the bench,
# minus the four that are about the Pi's own boot chain, which skip themselves.
#
# No place to acquire and no coordinator: there is no shared hardware here, so
# this runs anywhere the dev shell does, including alongside a bench run.
#
# What it cannot do is discovery and pairing: user-mode networking carries no
# mDNS, and Home Assistant opens connections *to* a device. Those stay on the
# bench until this target grows a tap interface.
[doc('Run the suite against the x86_64 image under QEMU')]
qemu-test *ARGS: build-disk-image-dev
  pytest labgrid/ --lg-env labgrid/qemu-x86.yaml -v {{ARGS}}

# Prove the bench is healthy before anything blames the image. Read-only apart
# from routing the card to the bench host and back, and the first thing to run
# when a hardware run looks wrong — it checks every resource the exporter
# publishes, that the card is actually in the mux, that the probe and the mux are
# not on one USB controller, and that the plug still meters.
#
# Exits 2 on a bench fault, which no pytest assertion failure produces: a red
# gate has to mean the image, and this is what makes that true. A lossy console
# once reported itself as "3 passed, 13 skipped, 1 error" and cost a morning in
# the wrong half of the system (see labgrid/README.md).
#
# `--serial` additionally boots whatever is on the card and measures how much of
# the console arrives intact, which is the check that settles a lossy probe. It
# needs a bootable card, so it is opt-in rather than part of the default run.
[doc('Check the bench is healthy before trusting a run')]
hw-preflight *ARGS:
  ./labgrid/with-place.sh \
    "${LABGRID_PYTHON:?not set — enter the dev shell with 'nix develop' or 'direnv allow'}" \
    labgrid/preflight.py {{ARGS}}

# Provision the bench board for real: write a seed file with an actual Home
# Assistant URL (and optionally Wi-Fi) onto the running board, trigger the
# first-boot importer, and report what the device did with it. Unlike the test,
# which uses a documentation-range URL and asserts, this is for seeing the result
# in Home Assistant.
#
# Keep the Wi-Fi passphrase out of shell history and out of this repo — pass it in
# the environment, ideally via secretspec:
#   DA_WIFI_PSK=... just hw-seed --ha-url http://192.168.178.73:8123 --wifi-ssid MyNet
[doc('Provision the bench board from a real seed file')]
hw-seed *ARGS:
  ./labgrid/with-place.sh \
    "${LABGRID_PYTHON:?not set — enter the dev shell with 'nix develop' or 'direnv allow'}" \
    labgrid/seed.py {{ARGS}}

# Flash the Pi 5 dev image onto the bench board and run the hardware first-boot
# tests against it: labgrid acquires the place, switches the USB-SD-Mux to the
# bench host, rsyncs the image there and dd's it onto the card, hands the card
# back to the board, cycles the plug and logs in over the Debug Probe's UART.
# Roughly 4 GiB of dd plus a first boot that resizes the filesystem, so budget
# several minutes. The image only crosses the network when it changes.
#
# Builds first because the tests flash whatever is currently in result-rpi5-dev/ —
# forgetting to rebuild is how you spend ten minutes testing the previous commit.
# The image must be the *dev* flavour: the release image has no console password
# and cannot be driven (see labgrid/README.md).
#
# While iterating on assertions, hold the place and skip the reflash entirely:
#   just hw-acquire && pytest labgrid/ --lg-initial-state shell
[doc('Flash the Pi 5 dev image to the bench board and assert first boot')]
hw-test *ARGS: build-rpi5-dev
  ./labgrid/with-place.sh pytest labgrid/ -v {{ARGS}}

# Flash the bench board and stop, leaving the card in the board's hands and the
# power off. For bringing a board up by hand, or bisecting a boot failure where
# the assertions are not the interesting part. Same image discovery as hw-test.
# No test wants the `flashed` state on its own, so this drives the strategy
# directly rather than inventing a test that asserts nothing. LABGRID_PYTHON, not
# python3: the dev shell has more than one interpreter on PATH and only that one
# has labgrid (see flake.nix).
[doc('Flash the bench board and stop there')]
hw-flash *ARGS: build-rpi5-dev
  ./labgrid/with-place.sh \
    "${LABGRID_PYTHON:?not set — enter the dev shell with 'nix develop' or 'direnv allow'}" \
    labgrid/flash.py {{ARGS}}

# Watch the bench board's serial console. This is the tool for the questions the
# harness cannot answer for you: which tty the console actually lands on, what the
# shell prompt looks like, and what U-Boot printed before it gave up. Ctrl-\ to
# get microcom's prompt, then q to quit.
#
# Goes through the coordinator rather than the probe's device node, which does not
# exist on this machine — the exporter runs ser2net on the bench host and the
# console arrives over rfc2217. It allows several connections, so this does not
# fight a running test for the port.
[doc("Watch the bench board's serial console")]
hw-console:
  ./labgrid/with-place.sh labgrid-client -p "$LG_PLACE" console

# Drive the bench plug by hand: on, off, cycle or get.
#
# `get` reports the relay, which is what the plug was *told* to do. For what the
# board is actually drawing — the way to tell a running board from a dead one —
# the plug's own meter is at $plug/meter/0, and test_board_draws_power asserts on
# it (see labgrid/bench.py).
[doc('on | off | cycle | get on the bench plug')]
hw-power ACTION:
  ./labgrid/with-place.sh labgrid-client -p "$LG_PLACE" power {{ACTION}}

# Hold the bench across several runs, which is the companion to
# `pytest labgrid/ --lg-initial-state shell`: acquire once, iterate on assertions
# against a board that is already up, release when done. The hw-* recipes notice
# the place is already held and leave it that way.
[doc('Acquire the bench place and keep it')]
hw-acquire:
  labgrid-client -p "$LG_PLACE" acquire

[doc('Release the bench place')]
hw-release:
  labgrid-client -p "$LG_PLACE" release

# Apply the R2 bucket lifecycle policy from ops/r2-lifecycle.json (R2 speaks the
# S3 PutBucketLifecycleConfiguration API). Needs R2_ACCOUNT_ID + R2 S3 credentials
# in the environment; run it through secretspec so those come from your provider
# (pass), and R2_BUCKET defaults to the images bucket. See ops/README.md.
#   secretspec run -- just r2-lifecycle-apply
[doc('Apply ops/r2-lifecycle.json to the R2 images bucket')]
r2-lifecycle-apply:
  #!/usr/bin/env bash
  set -euo pipefail
  : "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID (Cloudflare account id)}"
  : "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID (R2 S3 token id)}"
  : "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY (R2 S3 token secret)}"
  bucket="${R2_BUCKET:-dashboard-assistant}"
  aws s3api put-bucket-lifecycle-configuration \
    --bucket "$bucket" \
    --lifecycle-configuration file://ops/r2-lifecycle.json \
    --endpoint-url "https://${R2_ACCOUNT_ID}.eu.r2.cloudflarestorage.com" \
    --region auto
  echo "Applied ops/r2-lifecycle.json to bucket '$bucket'."

# Print the lifecycle policy currently applied to the R2 images bucket.
[doc("Print the R2 images bucket's current lifecycle policy")]
r2-lifecycle-show:
  #!/usr/bin/env bash
  set -euo pipefail
  : "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID (Cloudflare account id)}"
  : "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID (R2 S3 token id)}"
  : "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY (R2 S3 token secret)}"
  bucket="${R2_BUCKET:-dashboard-assistant}"
  aws s3api get-bucket-lifecycle-configuration \
    --bucket "$bucket" \
    --endpoint-url "https://${R2_ACCOUNT_ID}.eu.r2.cloudflarestorage.com" \
    --region auto

# List the dashboard.* config options this OS defines (name, type, default,
# description). Introspects the NixOS module options via optionAttrSetToDocList.
[doc('List the dashboardAssistant.* NixOS config options')]
options:
  #!/usr/bin/env bash
  set -euo pipefail
  nix eval --impure --json --expr '
    let
      f = builtins.getFlake (toString ./.);
      lib = f.inputs.nixpkgs-unstable.lib;
      docs = lib.optionAttrSetToDocList f.nixosConfigurations.dashboard-assistant-x86-disk.options.dashboardAssistant;
    in map (o: {
      name = o.name;
      type = o.type;
      default = if o ? default then (o.default.text or (builtins.toJSON o.default)) else "-";
      description = o.description or "";
    }) (builtins.filter (o: o.visible && !o.internal) docs)
  ' | jq -r '
    sort_by(.name)[] |
    "\(.name)   (\(.type), default: \(.default))\n    \((.description // "") | gsub("[[:space:]]+";" ") | ltrimstr(" ") | if length>180 then .[0:180]+"…" else . end)\n"
  '
