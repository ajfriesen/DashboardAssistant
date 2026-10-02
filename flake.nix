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
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Second channel for targets that need newer bits than the pinned stable
    # release. The Raspberry Pi 5 image is built from this (its kernel/firmware
    # and the sd-image pi5 support only landed post-26.05). The x86 / Pi 4
    # targets stay on nixpkgs (26.05) by default but can be flipped to unstable
    # per build with `--override-input nixpkgs` — see the *-unstable just recipes.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Wired for the future on-disk install path (tmpfs root + ext4 /persist).
    # Scaffolding only so far — see the commented block in modules/core/default.nix.
    impermanence.url = "github:nix-community/impermanence";

    # Declarative btrfs+zstd disk layout + image builder for the on-disk target.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Board profiles (firmware, GPU, kernel bits) for the Raspberry Pi target.
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      impermanence,
      disko,
      nixos-hardware,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # Docs tooling only. The 26.05 pin carries zensical 0.0.43 (and the 26.05
      # branch tip still does — no backports), while the docs workflow installs
      # the latest from PyPI, so `zensical serve` locally would render with a
      # much older generator than the one that builds dashboardassistant.org.
      # Nothing in the images comes from here; see the devShell below.
      pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
      lib = nixpkgs.lib;

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
      # can cut both a stable and a dev flavour from the same base.
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

      # The Pi 5 system, parameterised the same way, so its stable and dev
      # flavours cannot drift apart. nixpkgs-unstable's lib.nixosSystem for the
      # same reason the stable flavour uses it (see below).
      mkRpi5System =
        extraModules:
        nixpkgs-unstable.lib.nixosSystem {
          system = "aarch64-linux";
          # pkgsBuild is the *build machine's* pkgs, used only to run disko's
          # image-builder VM at native speed; see
          # dashboardAssistant.diskImage.builderPkgs. It has to come from the
          # same channel as the system (unstable here) so the VM's kernel and
          # qemu match the disko module instance.
          specialArgs = {
            inherit impermanence version;
            pkgsBuild = nixpkgs-unstable.legacyPackages.${system};
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
        # Stable release — persistent, boots from a fixed SATA disk, updatable
        # with `nixos-rebuild switch`. A released device is reconfigured only via
        # the USB seed file. Build via `.#disk-image`. (sshd needs no override any
        # more: modules/core/debug.nix only enables it when a root key is declared,
        # which only the *-dev flavours do.)
        dashboard-assistant-x86-disk = mkDiskSystem [ ];

        # Dev flavour of the on-disk system — same base plus modules/dev.nix
        # (root SSH access). Build via `.#disk-image-dev`.
        dashboard-assistant-x86-disk-dev = mkDiskSystem [ ./modules/dev.nix ];

        # Raspberry Pi 4 (aarch64) — SD-card image, for bring-up/testing on a Pi.
        # Build the flashable image via `.#rpi4-image` (aarch64; this host builds
        # it via binfmt emulation, fetching most from the binary cache).
        dashboard-assistant-rpi4 = lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            inherit impermanence version;
            pkgsBuild = pkgs;
          };
          modules = [
            disko.nixosModules.disko
            nixos-hardware.nixosModules.raspberry-pi-4
            ./modules/hardware/rpi4.nix
            ./modules/core/default.nix
          ]
          ++ localModules;
        };

        # Raspberry Pi 5 (aarch64) — SD-card image. Built from nixpkgs-unstable
        # (its lib.nixosSystem, so it is pinned to unstable regardless of any
        # `--override-input nixpkgs` on the other targets): the Pi 5 kernel and
        # the sd-image pi5 support are newer than the pinned 26.05. Build the
        # flashable image via `.#rpi5-image`.
        dashboard-assistant-rpi5 = mkRpi5System [ ];

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
        dashboard-assistant-rpi5-dev = mkRpi5System [ ./modules/dev.nix ];
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
      };

      # Raspberry Pi SD-card images, built by disko from the same
      # modules/hardware/disk-layout.nix the x86 image uses — so all three
      # targets emit a raw GPT image and are flashed identically:
      #   sudo dd if=result-rpi5/dashboard-assistant-rpi5.raw of=/dev/sdX ...
      #
      # These are aarch64 derivations built on an x86 host through binfmt, but
      # the image-builder VM itself runs natively (see
      # dashboardAssistant.diskImage.builderPkgs), so only nixos-install's
      # chroot is emulated.
      packages.aarch64-linux.rpi4-image =
        self.nixosConfigurations.dashboard-assistant-rpi4.config.system.build.diskoImages;

      packages.aarch64-linux.rpi5-image =
        self.nixosConfigurations.dashboard-assistant-rpi5.config.system.build.diskoImages;

      # Same image plus root SSH, for debugging on real hardware without
      # reflashing between changes: `nix build .#rpi5-image-dev`.
      packages.aarch64-linux.rpi5-image-dev =
        self.nixosConfigurations.dashboard-assistant-rpi5-dev.config.system.build.diskoImages;

      # VM tests. `nix flake check`, or `nix build .#checks.x86_64-linux.first-boot`
      # for one.
      checks.${system} = {
        first-boot = import ./tests/first-boot.nix { inherit pkgs version; };
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
          # From unstable on purpose — see pkgsUnstable above.
          pkgsUnstable.zensical
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
          labgridPython
          # labgrid's USBSDMuxDriver does not talk to the mux itself, it execs
          # this. Needs the host side too (sg module + udev rules) — see
          # labgrid/README.md.
          pkgs.usbsdmux
          # Inspect a built sd-image's FAT partition without mounting it or
          # needing root: `mdir`/`mtype`/`minfo -i "$img@@$((16384*512))"` reads
          # partition 1 straight out of the .img, `partx` finds its offset, and
          # `fsck.vfat` checks the extracted filesystem. That is how the README
          # and example seed file staged onto the firmware partition get verified
          # (modules/core/configimport.nix), and labgrid/README.md has documented
          # an mcopy invocation this shell could not run until now.
          pkgs.mtools
          pkgs.dosfstools
          pkgs.util-linux
          # `just hw-console`: watch the board's UART by hand, which is how you
          # confirm the console lands where the harness expects.
          pkgs.picocom
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
