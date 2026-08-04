# Show this help menu (default when `just` is run with no arguments).
help:
  @echo "dashboard-assistant OS — just recipes"
  @echo
  @echo "Build images:"
  @echo "  build-live-iso            Build the installer ISO (x86)"
  @echo "  build-disk-image             Build the stable raw disk image (btrfs+zstd)"
  @echo "  build-disk-image-dev         Build the dev raw disk image (SSH + debugging)"
  @echo "  build-disk-image-unstable    Build the raw disk image against nixos-unstable"
  @echo "  build-rpi4             Build the Raspberry Pi 4 SD-card image (aarch64)"
  @echo "  build-rpi5             Build the Raspberry Pi 5 SD-card image (aarch64, unstable)"
  @echo
  @echo "Run / connect (QEMU):"
  @echo "  qemu-run               Boot the built ISO in QEMU"
  @echo "  qemu-ssh               SSH into the VM, tunnelling the daemon (:8080) and CDP (:9222)"
  @echo "  net-check              Hit the networking API from inside the guest"
  @echo
  @echo "Drive the kiosk (needs qemu-ssh running):"
  @echo "  inject-token TOKEN     Log the kiosk into HA by injecting a long-lived token via CDP"
  @echo "  cdp-eval EXPR          Evaluate arbitrary JS in the kiosk page over CDP"
  @echo
  @echo "Introspect:"
  @echo "  options                List the dashboard.* NixOS config options"
  @echo
  @echo "R2 images bucket:"
  @echo "  r2-lifecycle-apply     Apply ops/r2-lifecycle.json to the bucket"
  @echo "  r2-lifecycle-show      Print the bucket's current lifecycle policy"
  @echo
  @echo "Run 'just --list' for the raw recipe list."

[doc('Build the installer ISO (x86)')]
build-live-iso:
  nix build .#nixosConfigurations.dashboard-assistant-x86-live.config.system.build.isoImage
  @iso=$(ls "$(readlink -f result)"/iso/*.iso); \
    echo; \
    echo "Image: $iso"; \
    echo "Flash it to a spare USB stick (confirm the device first!):"; \
    echo "  sudo dd if=$iso of=/dev/disk/by-id/ata-WDC_WDS100T2B0A-00SM50_195206A003DE bs=4M oflag=sync conv=fsync status=progress"; \
    echo; \
    echo "Then boot the target from that USB: it lists the internal disks, asks"; \
    echo "which one to erase, installs onto it, and powers off to swap the stick."

# Build the stable installable raw disk image (btrfs+zstd, built by disko). No
# SSH daemon; reconfigure a deployed device only via the USB seed file. dd
# result/dashboard-assistant.raw to the SSD, then boot it from the native SATA port.
[doc('Build the stable raw disk image (btrfs+zstd)')]
build-disk-image:
  nix build .#disk-image
  @echo
  @echo "Image: $(readlink -f result)/dashboard-assistant.raw"
  @echo "Flash it (confirm the device first!):"
  @echo "  sudo dd if=$(readlink -f result)/dashboard-assistant.raw of=/dev/disk/by-id/ata-WDC_WDS100T2B0A-00SM50_195206A003DE bs=4M oflag=sync conv=fsync status=progress"

# Build the dev raw disk image — same as build-disk-image plus modules/dev.nix
# (root SSH access, diagnostics, Chromium remote debugging). For bench/field
# debugging only; never flash this onto a released device.
[doc('Build the dev raw disk image (SSH + debugging)')]
build-disk-image-dev:
  nix build .#disk-image-dev
  @echo
  @echo "Image: $(readlink -f result)/dashboard-assistant.raw"
  @echo "Flash it (confirm the device first!):"
  @echo "  sudo dd if=$(readlink -f result)/dashboard-assistant.raw of=/dev/disk/by-id/ata-WDC_WDS100T2B0A-00SM50_195206A003DE bs=4M oflag=sync conv=fsync status=progress"

# Build the stable raw disk image against nixos-unstable instead of the pinned
# 26.05. --override-input swaps the flake's nixpkgs (disko follows it, so its
# closure moves too); nothing is written to flake.lock. The same trick flips any
# other recipe: append `--override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable`.
[doc('Build the stable raw disk image against nixos-unstable')]
build-disk-image-unstable:
  nix build .#disk-image --override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable
  @echo
  @echo "Image: $(readlink -f result)/dashboard-assistant.raw"
  @echo "Flash it (confirm the device first!):"
  @echo "  sudo dd if=$(readlink -f result)/dashboard-assistant.raw of=/dev/disk/by-id/ata-WDC_WDS100T2B0A-00SM50_195206A003DE bs=4M oflag=sync conv=fsync status=progress"

# Build the Raspberry Pi 4 (aarch64) SD-card image. On an x86 host the aarch64
# closure builds via binfmt emulation — but once CI has populated the public
# Attic cache (.github/workflows/cache-rpi.yml), --accept-flake-config lets the
# flake's extra-substituter pull the kernel + system instead of recompiling it,
# so this is a download rather than a slow emulated build. Falls back to building
# if the cache is cold or unreachable. Then flash the image to an SD card.
# Note: the flake substituter is only honoured if you're a trusted Nix user
# (nix.settings.trusted-users on this workstation).
[doc('Build the Raspberry Pi 4 SD-card image (aarch64)')]
build-rpi4:
  nix build .#packages.aarch64-linux.rpi4-image --accept-flake-config --out-link result-rpi4
  @echo
  @echo "Image: $(readlink -f result-rpi4)/sd-image/"*.img.zst
  @echo "Flash it (confirm the device first!):"
  @echo "  zstdcat result-rpi4/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync"

# Build the Raspberry Pi 5 (aarch64) SD-card image. Always built from
# nixos-unstable (pinned in flake.nix, not via override): the Pi 5 kernel and
# the sd-image pi5 support are newer than the pinned 26.05. Same emulated-build /
# binary-cache story as build-rpi4. Then flash the image to an SD card.
[doc('Build the Raspberry Pi 5 SD-card image (aarch64, unstable)')]
build-rpi5:
  nix build .#packages.aarch64-linux.rpi5-image --accept-flake-config --out-link result-rpi5
  @echo
  @echo "Image: $(readlink -f result-rpi5)/sd-image/"*.img.zst
  @echo "Flash it (confirm the device first!):"
  @echo "  zstdcat result-rpi5/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync"

# Boot the built ISO. The virtio-net NIC gets DHCP from QEMU's user-mode
# network, so NetworkManager auto-connects it — first boot lands in the setup
# wizard showing "Connected via ethernet" (the wired / existing-connection path).
# Interact with the wizard directly on the QEMU display, or drive it from the
# host via `just qemu-ssh` (see the loopback note there).
[doc('Boot the built ISO in QEMU')]
qemu-run:
  qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 -smp 2 \
    -machine q35 \
    -cdrom result/iso/*.iso \
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
# :9222) and dashboard.debug.chromiumRemoteDebugging = true baked into the image.
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
[doc('List the dashboard.* NixOS config options')]
options:
  #!/usr/bin/env bash
  set -euo pipefail
  nix eval --impure --json --expr '
    let
      f = builtins.getFlake (toString ./.);
      lib = f.inputs.nixpkgs.lib;
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
