# Public Nix binary cache (Attic, backed by Cloudflare R2), shared by every image.
#
# Baking the substituter into the *system* config — not just a dev workstation's
# nix.conf — is what makes OTA updates fast: the update rebuild
# (modules/core/update.nix) runs `nixos-rebuild switch` as root, and a
# system-level substituter is trusted by default, so every deployed Pi / x86 box
# downloads the closure (the linux-rpi kernel included) instead of recompiling
# it under emulation.
#
# It is a pure accelerator: if the cache is unreachable, Nix falls back to
# building, and because store paths are input-addressed the resulting system is
# byte-identical either way — which is exactly the property that keeps the fleet
# supportable.
#
# The cache is public: pulling needs no token. CI populates it via
# .github/workflows/cache-rpi.yml (push access uses a secret token there). The
# public key below is non-secret and only used to verify signatures on pull.
{ lib, ... }:
let
  # Single source of truth for the cache location (Attic cache name is
  # "dashboardassistant", no hyphen — matches the server's Binary Cache Endpoint).
  substituter = "https://nix-cache.dashboardassistant.org/dashboardassistant";

  # Non-secret cache signing key (from `attic cache info dashboardassistant`),
  # used only to verify signatures on pulled paths.
  publicKey = "dashboardassistant:qyNbqk1+S/2a2dqe7XcDfCGnSGT6ACBXgPr5/4BNLYU=";
in
{
  nix.settings = {
    extra-substituters = [ substituter ];
    extra-trusted-public-keys = lib.optional (publicKey != null) publicKey;
  };
}
