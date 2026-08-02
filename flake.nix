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
    # Not heavily used yet: the live ISO already provides an ephemeral root.
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
      lib = nixpkgs.lib;

      # Release version baked into every image. The daemon reports this to Home
      # Assistant as the "installed" version and compares it against the newest
      # GitHub release tag to advertise updates. Bump it in lockstep with the
      # release tag you cut (tags may carry a leading "v"; the daemon strips it).
      version = "0.2.0";

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
    in
    {
      nixosConfigurations = {
        # Installer ISO — boots from removable media (a spare USB stick) into a
        # console installer that asks which internal disk to erase, then writes
        # the persistent system below onto it. Deliberately does NOT run the
        # kiosk itself, and does NOT take localModules: the installer needs none
        # of the seed/kiosk options, and the system it writes carries them.
        dashboard-assistant-x86-live = lib.nixosSystem {
          inherit system;
          specialArgs = { inherit impermanence version; };
          modules = [
            ./modules/hardware/generic-x86.nix
            ./modules/installer/installer.nix
            { installer.diskSystem = self.nixosConfigurations.dashboard-assistant-x86-disk; }
          ];
        };

        # Stable release — persistent, boots from a fixed SATA disk, updatable
        # with `nixos-rebuild switch`. No SSH daemon at all (overrides the
        # convenience default in core/default.nix): a released device is
        # reconfigured only via the USB seed file. Build via `.#disk-image`.
        dashboard-assistant-x86-disk = mkDiskSystem [
          { services.openssh.enable = lib.mkForce false; }
        ];

        # Dev flavour of the on-disk system — same base plus modules/dev.nix
        # (diagnostics, Chromium remote debugging, root SSH access). Build via
        # `.#disk-image-dev`.
        dashboard-assistant-x86-disk-dev = mkDiskSystem [ ./modules/dev.nix ];

        # Raspberry Pi 4 (aarch64) — SD-card image, for bring-up/testing on a Pi.
        # Build the flashable image via `.#rpi4-image` (aarch64; this host builds
        # it via binfmt emulation, fetching most from the binary cache).
        dashboard-assistant-rpi4 = lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit impermanence version; };
          modules = [
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
        dashboard-assistant-rpi5 = nixpkgs-unstable.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit impermanence version; };
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-5
            ./modules/hardware/rpi5.nix
            ./modules/core/default.nix
          ]
          ++ localModules;
        };
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
        vboard = pkgs.callPackage ./packages/vboard.nix { };
      };

      # Raspberry Pi 4 SD-card image: `nix build .#rpi4-image`, then flash
      # result/sd-image/*.img.zst to the card (zstdcat | dd, or unzstd first).
      packages.aarch64-linux.rpi4-image =
        self.nixosConfigurations.dashboard-assistant-rpi4.config.system.build.sdImage;

      # Raspberry Pi 5 SD-card image (built from unstable): `nix build .#rpi5-image`,
      # then flash result/sd-image/*.img.zst to the card (same as the Pi 4).
      packages.aarch64-linux.rpi5-image =
        self.nixosConfigurations.dashboard-assistant-rpi5.config.system.build.sdImage;

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
        ];
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
