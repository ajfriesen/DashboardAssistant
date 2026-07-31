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

        # Installed system — persistent, boots from a fixed SATA disk, updatable
        # with `nixos-rebuild switch`. Build a flashable image via `.#disk-image`.
        dashboard-assistant-x86-disk = lib.nixosSystem {
          inherit system;
          specialArgs = { inherit impermanence version; };
          modules = [
            disko.nixosModules.disko
            ./modules/hardware/generic-x86-disk.nix
            ./modules/core/default.nix
          ]
          ++ localModules;
        };

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
      };

      # Raw btrfs+zstd EFI disk image built by disko: `nix build .#disk-image`
      # (or `just build-disk`), then dd result/dashboard-assistant.raw to the SSD. The
      # layout lives in modules/hardware/disk-layout.nix.
      packages.${system} = {
        disk-image = self.nixosConfigurations.dashboard-assistant-x86-disk.config.system.build.diskoImages;

        # vboard (on-screen keyboard) is packaged from source — not in nixpkgs.
        # Exposed here so it can be built/tested standalone (`nix build .#vboard`);
        # the kiosk module pulls it in via callPackage.
        vboard = pkgs.callPackage ./packages/vboard.nix { };
      };

      # Raspberry Pi 4 SD-card image: `nix build .#rpi4-image`, then flash
      # result/sd-image/*.img.zst to the card (zstdcat | dd, or unzstd first).
      packages.aarch64-linux.rpi4-image =
        self.nixosConfigurations.dashboard-assistant-rpi4.config.system.build.sdImage;

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
