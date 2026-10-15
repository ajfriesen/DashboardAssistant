{
  description = "Dashboard Assistant OS — declarative single-purpose Home Assistant kiosk";

  # Public Attic (Nix binary cache on Cloudflare R2) so local builds — notably
  # `just build-rpi4`, whose aarch64 kernel is otherwise compiled under slow
  # binfmt emulation — download the closure instead of rebuilding it. This is the
  # dev-workstation counterpart of modules/core/binary-cache.nix (which bakes the
  # same cache into deployed images). Nix only honours these for a trusted user,
  # so builds pass `--accept-flake-config` (see the justfile) and you must be in
  # nix.settings.trusted-users on your workstation. Keep in sync with
  # modules/core/binary-cache.nix (which bakes the same cache into images).
  nixConfig = {
    extra-substituters = [ "https://nix-cache.dashboardassistant.org/dashboardassistant" ];
    extra-trusted-public-keys = [ "dashboardassistant:qyNbqk1+S/2a2dqe7XcDfCGnSGT6ACBXgPr5/4BNLYU=" ];
  };

  inputs = {
    # The one nixpkgs every board builds from: nixos-unstable, pinned by
    # flake.lock and bumped on purpose about once a month with
    # `nix flake update nixpkgs-unstable` (docs/adr/0008, developer/README.md).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Wired for the future on-disk install path (tmpfs root + ext4 /persist).
    # Scaffolding only so far — see the commented block in modules/core/default.nix.
    impermanence.url = "github:nix-community/impermanence";

    # Declarative btrfs+zstd disk layout + image builder for the on-disk target.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs-unstable";

    # Board profiles (firmware, GPU, kernel bits) for the Raspberry Pi target.
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs =
    {
      self,
      nixpkgs-unstable,
      impermanence,
      disko,
      nixos-hardware,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs-unstable.legacyPackages.${system};
      lib = nixpkgs-unstable.lib;

      # Release version baked into every image. The daemon reports this to Home
      # Assistant as the "installed" version and compares it against the newest
      # GitHub release tag to advertise updates. release-please bumps this line in
      # the release PR to match the tag it cuts (via the x-release-please-version
      # annotation; tags may carry a leading "v", which the daemon strips) — don't
      # edit it by hand.
      version = "1.0.0-rc.1"; # x-release-please-version

      # Interpreter for the hardware bench (labgrid/). labgrid and pytest have to
      # share one env: labgrid ships its fixtures as a pytest11 entry point, so a
      # pytest from any other Python simply does not see them and --lg-env becomes
      # an unknown option. Bound here rather than inline in the devShell so the
      # interpreter itself can be exported as LABGRID_PYTHON — other packages in
      # the shell (zensical) drag their own python3 onto PATH, and which one wins
      # is an accident of ordering.
      labgridPython = pkgs.python314.withPackages (ps: [
        ps.labgrid
        ps.pytest
      ]);

      # Optional per-build overrides (e.g. a seeded HA URL / debug flags). See
      # modules/local.example.nix. Must be git-tracked to be picked up.
      localModules = lib.optional (builtins.pathExists ./modules/local.nix) ./modules/local.nix;

      # The on-disk x86 system, parameterised by a list of extra modules so we
      # can cut both a release and a dev flavour from the same base.
      mkDiskSystem =
        extraModules:
        lib.nixosSystem {
          inherit system;
          specialArgs = { inherit impermanence version; };
          modules = [
            disko.nixosModules.disko
            ./modules/hardware/generic-x86-disk.nix
            ./modules/core/default.nix
          ]
          ++ localModules
          ++ extraModules;
        };

      # The Pi systems, parameterised by extra modules (so the release and dev
      # flavours cannot drift apart) and by builderPkgs — the *build machine's*
      # pkgs, used only to run disko's image-builder VM at native speed; see
      # dashboardAssistant.diskImage.builderPkgs. Pass the build host's pkgs
      # when cross-building from x86 (it must come from the same nixpkgs as
      # the system, so the VM's kernel and qemu match the disko module
      # instance), or null on a native aarch64 builder, which leaves the VM
      # native and binfmt off. Hardcoding x86_64 here was exactly wrong on an
      # ARM host: it put a foreign qemu and kernel inside the builder VM.
      mkRpi4System =
        builderPkgs: extraModules:
        lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            inherit impermanence version;
            pkgsBuild = builderPkgs;
          };
          modules = [
            disko.nixosModules.disko
            nixos-hardware.nixosModules.raspberry-pi-4
            ./modules/hardware/rpi4.nix
            ./modules/core/default.nix
          ]
          ++ localModules
          ++ extraModules;
        };

      mkRpi5System =
        builderPkgs: extraModules:
        lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            inherit impermanence version;
            pkgsBuild = builderPkgs;
          };
          modules = [
            disko.nixosModules.disko
            nixos-hardware.nixosModules.raspberry-pi-5
            ./modules/hardware/rpi5.nix
            ./modules/core/default.nix
          ]
          ++ localModules
          ++ extraModules;
        };
    in
    {
      nixosConfigurations = {
        # Release image — persistent, boots from a fixed SATA disk, updatable
        # with `nixos-rebuild switch`. A released device is reconfigured only via
        # the USB seed file. Build via `.#disk-image`. (sshd needs no override any
        # more: modules/core/debug.nix only enables it when a root key is declared,
        # which only the *-dev flavours do.)
        dashboard-assistant-x86-disk = mkDiskSystem [ ];

        # Dev flavour of the on-disk system — same base plus modules/dev.nix
        # (root SSH access). Build via `.#disk-image-dev`.
        dashboard-assistant-x86-disk-dev = mkDiskSystem [ ./modules/dev.nix ];

        # Raspberry Pi 4 (aarch64) — SD-card image, for bring-up/testing on a Pi.
        # Build the flashable image via `.#rpi4-image` (aarch64; an x86 host
        # builds it via binfmt emulation, fetching most from the binary cache).
        dashboard-assistant-rpi4 = mkRpi4System pkgs [ ];

        # Raspberry Pi 5 (aarch64) — SD-card image. Build the flashable image
        # via `.#rpi5-image`.
        dashboard-assistant-rpi5 = mkRpi5System pkgs [ ];

        # Dev flavour of the Pi 5 image — same base plus modules/dev.nix, which
        # declares the root SSH keys that turn sshd on (see modules/core/debug.nix;
        # a release image has no sshd at all). This is the image to reach for when
        # a Pi needs debugging: it is reconfigurable in place with
        # `nixos-rebuild switch --flake .#dashboard-assistant-rpi5-dev --target-host`,
        # so iterating no longer means pulling the card and reflashing. Build via
        # `.#rpi5-image-dev` or `just build-rpi5-dev`.
        # Dev flavour of the Pi 5 image — same base plus modules/dev.nix.
        # No compression knob any more: disko emits a single uncompressed
        # .raw for every target, the same as the x86 images, and release
        # artifacts are compressed by the publishing workflow instead.
        dashboard-assistant-rpi5-dev = mkRpi5System pkgs [
          ./modules/dev.nix
        ];
      };

      # Raw btrfs+zstd EFI disk image built by disko: `nix build .#disk-image`
      # (or `just build-disk`), then dd result/dashboard-assistant.raw to the SSD. The
      # layout lives in modules/hardware/disk-layout.nix.
      packages.${system} = {
        disk-image = self.nixosConfigurations.dashboard-assistant-x86-disk.config.system.build.diskoImages;
        disk-image-dev =
          self.nixosConfigurations.dashboard-assistant-x86-disk-dev.config.system.build.diskoImages;

        # vboard (on-screen keyboard) is packaged from source — not in nixpkgs.
        # Exposed here so it can be built/tested standalone (`nix build .#vboard`);
        # the kiosk module pulls it in via callPackage.
        vboard = pkgs.callPackage ./packages/vboard/vboard.nix { };

        # sendspin-player (multi-room audio client) — likewise packaged from
        # source and exposed for standalone builds (`nix build .#sendspin-player`);
        # modules/core/sendspin.nix pulls it in via callPackage.
        sendspin-player = pkgs.callPackage ./packages/sendspin-go/sendspin-go.nix { };

        # Raspberry Pi SD-card images, cross-built *from this x86 host*: the
        # aarch64 system compiles under binfmt while disko's image-builder VM
        # runs natively on x86 (see dashboardAssistant.diskImage.builderPkgs).
        # This bucket is what an x86 workstation and CI build — `nix build
        # .#rpi5-image` resolves here. The aarch64-linux bucket below carries
        # the same images wired for a *native* aarch64 builder instead.
        rpi4-image = self.nixosConfigurations.dashboard-assistant-rpi4.config.system.build.diskoImages;
        rpi5-image = self.nixosConfigurations.dashboard-assistant-rpi5.config.system.build.diskoImages;
        rpi5-image-dev =
          self.nixosConfigurations.dashboard-assistant-rpi5-dev.config.system.build.diskoImages;
      };

      # The same Pi images for a *native* aarch64 builder (an ARM runner or a
      # developer's ARM machine): builderPkgs stays null, so disko's builder VM
      # is aarch64 itself and no binfmt is involved. All targets emit a raw GPT
      # image from the one layout in modules/hardware/disk-layout.nix and are
      # flashed identically:
      #   sudo dd if=result-rpi5/dashboard-assistant-rpi5.raw of=/dev/sdX ...
      #
      # Kept separate from the x86 bucket above because the right builder VM
      # depends on the machine evaluating the build — these attrs used to be
      # hard-wired to an x86_64 builder VM, which inverted the native-speed
      # trick on exactly the hosts whose system the attr path names.
      packages.aarch64-linux = {
        rpi4-image = (mkRpi4System null [ ]).config.system.build.diskoImages;
        rpi5-image = (mkRpi5System null [ ]).config.system.build.diskoImages;
        # Same image plus root SSH, for debugging on real hardware without
        # reflashing between changes: `nix build .#rpi5-image-dev`.
        rpi5-image-dev = (mkRpi5System null [ ./modules/dev.nix ]).config.system.build.diskoImages;
      };

      # VM tests. `nix flake check`, or `nix build .#checks.x86_64-linux.first-boot`
      # for one. Adding a check here means adding its name to the matrix in
      # .github/workflows/vm-tests.yml too, or it never runs on a PR.
      checks.${system} = {
        first-boot = import ./tests/first-boot.nix { inherit pkgs version; };

        # Flash-wear flags on the browser command line. This is an eval-time
        # check rather than an assertion in first-boot.nix because that test
        # force-disables greetd (no GPU — Chromium crash-loops and buries the
        # signals the test is about), so no VM test can ever see the Chromium
        # command line. The flags would therefore be free to disappear, and the
        # only symptom would be customers' SD cards wearing out months later.
        kiosk-flash-flags =
          pkgs.runCommand "kiosk-flash-flags"
            {
              launcher =
                self.nixosConfigurations.dashboard-assistant-x86-disk.config.dashboardAssistant.kiosk.launcher;
            }
            ''
              set -euo pipefail
              # fail= accumulator so every sub-assertion reports before exiting,
              # matching .github/workflows/cache-rpi.yml.
              fail=0
              grep -q 'XDG_CACHE_HOME=.*kiosk-cache' "$launcher" || {
                echo "FAIL: the kiosk browser cache is back on flash — Chromium's HTTP and V8 code caches will write to the SD card continuously." >&2
                fail=1
              }
              grep -q -- '--disk-cache-size=' "$launcher" || {
                echo "FAIL: no --disk-cache-size — Chromium sizes its cache from free space, which on a tmpfs is most of RAM, so systemd-oomd will kill the kiosk session in a loop." >&2
                fail=1
              }
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # Every board on one nixpkgs (docs/adr/0008). The VM tests above only
        # ever evaluate x86, so a board quietly put back on another channel —
        # a second nixpkgs input wired into mkRpi4System, say — would pass every
        # other check while reintroducing the two configurations ADR 0008 exists
        # to remove. Compares the nixpkgs revision, not the release number, so
        # two different pins of the same release are caught too. Reading it out
        # of the aarch64 configs costs an eval, not a build.
        #
        # Also pins the x86 kernel to linuxPackages_latest: the channel's default
        # kernel trails mainline, and the newest one is what gives very recent
        # mini-PCs and laptops a working display, Wi-Fi and touch.
        one-nixpkgs =
          let
            x86 = self.nixosConfigurations.dashboard-assistant-x86-disk.config;
            rpi4 = self.nixosConfigurations.dashboard-assistant-rpi4.config;
            rpi5 = self.nixosConfigurations.dashboard-assistant-rpi5.config;
          in
          pkgs.runCommand "one-nixpkgs"
            {
              x86Rev = x86.system.nixos.revision;
              rpi4Rev = rpi4.system.nixos.revision;
              rpi5Rev = rpi5.system.nixos.revision;
              x86Kernel = x86.boot.kernelPackages.kernel.version;
              latestKernel = pkgs.linuxPackages_latest.kernel.version;
            }
            ''
              set -euo pipefail
              # fail= accumulator so every sub-assertion reports before exiting,
              # matching kiosk-flash-flags above.
              fail=0
              echo "x86: nixpkgs $x86Rev, kernel $x86Kernel"
              echo "rpi4: nixpkgs $rpi4Rev"
              echo "rpi5: nixpkgs $rpi5Rev"

              for board in rpi4:$rpi4Rev rpi5:$rpi5Rev; do
                [ "''${board#*:}" = "$x86Rev" ] || {
                  echo "FAIL: ''${board%%:*} is on nixpkgs ''${board#*:}, x86 on $x86Rev — every board must build from the one pinned nixpkgs-unstable (docs/adr/0008)." >&2
                  fail=1
                }
              done

              [ "$x86Kernel" = "$latestKernel" ] || {
                echo "FAIL: the x86 kernel is $x86Kernel, not linuxPackages_latest ($latestKernel) — very recent hardware loses its display, Wi-Fi or touch. See boot.kernelPackages in modules/hardware/generic-x86-disk.nix." >&2
                fail=1
              }

              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';

        # The screenshot handoff path has a writer in Nix (the in-session grim
        # agent) and a reader in Go (the daemon), with nothing coupling them.
        # If they drift, the HA image entity silently serves nothing — and on
        # the old path it silently wore the card instead.
        screenshot-path-agreement =
          pkgs.runCommand "screenshot-path-agreement"
            {
              kiosk = ./modules/core/kiosk.nix;
              daemonConfig = ./daemon/config.go;
            }
            ''
              set -euo pipefail
              fail=0
              want=/run/dashboard-assistant/screenshot.jpg
              grep -q "\"$want\"" "$kiosk" || {
                echo "FAIL: the grim agent no longer writes $want — the Home Assistant screenshot entity will time out." >&2
                fail=1
              }
              grep -q 'runtimeDir + "/screenshot.jpg"' "$daemonConfig" || {
                echo "FAIL: the daemon no longer reads the screenshot from the tmpfs runtime dir — frames are back on flash, at a rate a Home Assistant automation controls." >&2
                fail=1
              }
              [ "$fail" = 0 ] || exit 1
              touch "$out"
            '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.go
          pkgs.gopls
          pkgs.nixfmt
          # For `just inject-token` (CDP over the :9222 tunnel).
          pkgs.curl
          pkgs.jq
          pkgs.websocat
          # Static site generator for the docs/ site (`zensical serve`/`build`).
          pkgs.zensical
          # Conventional Commits: `cz commit` for a guided message, `cz check` to
          # lint one. Matches the integration repo's dev shell.
          pkgs.commitizen
          # Manage the Cloudflare R2 images bucket over its S3 API — notably apply
          # the lifecycle policy in ops/r2-lifecycle.json (`just r2-lifecycle-apply`).
          pkgs.awscli2
          # Declarative secrets: secretspec.toml declares the R2 credentials the
          # ops recipes need; `secretspec run -- <cmd>` resolves them from the
          # configured provider (pass/GPG) and injects them as env vars. pass +
          # gnupg back the default provider choice. See ops/README.md.
          pkgs.secretspec
          pkgs.pass
          pkgs.gnupg
          # `just qemu-run` boots the raw disk image, which is UEFI-only (the
          # bootloader lives in an EFI system partition), so QEMU needs firmware.
          pkgs.qemu
          pkgs.OVMF.fd
          # Drive real boards from the host: power, serial console, USB storage.
          # The VM tests cover what a VM can (see tests/), which leaves the
          # hardware-specific failures — U-Boot, firmware, the touchscreen — only
          # reproducible on a Pi or an x86 box sitting on the bench. See labgrid/
          # for the bench wiring and `just hw-test`.
          #
          # Puts pytest, labgrid-client, labgrid-exporter and labgrid-coordinator
          # on PATH. See the labgridPython binding above for why it is one env.
          #
          # Nothing hardware-side is needed here: the bench hangs off the bench
          # host, which exports it through a coordinator, so usbsdmux runs there
          # over ssh and the console comes back over ser2net (`labgrid-client
          # console`, Ctrl-\ to quit).
          labgridPython
          # Inspect a built sd-image's FAT partition without mounting it or
          # needing root: `mdir`/`mtype`/`minfo -i "$img@@$((2048*512))"` reads
          # partition 1 straight out of the .img, `partx` finds its offset, and
          # `fsck.vfat` checks the extracted filesystem. That is how the README
          # and example seed file staged onto the firmware partition get verified
          # (modules/core/configimport.nix), and labgrid/README.md has documented
          # an mcopy invocation this shell could not run until now.
          pkgs.mtools
          pkgs.dosfstools
          pkgs.util-linux

          # Repair the GPT of the scratch disk `just qemu-test` boots. That disk
          # is the image grown to leave first-boot growth something to grow
          # into, and growing a GPT disk leaves its backup header stranded in
          # the middle: Linux then rejects the table outright and the boot dies
          # in the initrd waiting for a root partition that it can no longer
          # see. `sgdisk --move-second-header` is the fix. See
          # labgrid/bench.py's prepare_qemu_disk.
          pkgs.gptfdisk
        ];

        # Unambiguous path to the interpreter that has labgrid, for scripts that
        # need to `import labgrid` rather than run pytest (`just hw-flash`). Bare
        # `python3` in this shell is whichever python landed on PATH first, which
        # is usually not this one.
        LABGRID_PYTHON = "${labgridPython}/bin/python3";

        # OVMF firmware for `just qemu-run`. Exported here rather than looked up
        # in the recipe so the VM boots the same firmware the pinned nixpkgs
        # provides, with no dependency on the flake registry.
        OVMF_FD = "${pkgs.OVMF.fd}/FV/OVMF.fd";

        # Point git at the version-controlled hook (.githooks/commit-msg) so every
        # commit is checked against Conventional Commits locally, not just PRs in
        # CI. Idempotent — safe to re-run on each shell entry.
        shellHook = ''
          if [ -d .git ]; then
            git config core.hooksPath .githooks
          fi
        '';
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
