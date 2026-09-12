# Vendored copy of nixpkgs' nixos/lib/make-btrfs-fs.nix with two changes:
# `--compress zstd` is passed to mkfs.btrfs.
#
# Why vendor it at all. sdImage.rootFilesystemCreator lets us swap the ext4
# builder for the btrfs one, but upstream's builder runs a plain
#
#   mkfs.btrfs -L <label> -U <uuid> -r ./rootImage --shrink $img
#
# with no compression. btrfs compression is decided per extent when the extent
# is written, and `compress=zstd` in fileSystems."/" only governs writes made
# *after* boot. So without this flag the Nix store we ship is stored
# uncompressed and stays that way until something happens to rewrite it —
# which for an appliance is never. The whole point of moving the Pi images to
# btrfs is that the shipped store is smaller, so the compression has to happen
# here, at image build time.
#
# `--compress` for `--rootdir` needs btrfs-progs >= 6.12; the pin is 7.1.
#
# SECOND divergence: an LD_PRELOAD shim (rootdir-owner-shim.c) replaces
# upstream's fakeroot in the mkfs step, because fakeroot silently ships images
# whose inodes are owned by the build user — see the comment at the mkfs
# invocation. Upstream has the same bug; check whether it is fixed before
# re-syncing.
#
# Re-diff this against upstream on a nixpkgs bump: everything below is verbatim
# except the marked lines, and the `compress` argument that feeds them.
{
  pkgs,
  lib,
  # List of derivations to be included
  storePaths,
  # Whether or not to compress the resulting image with zstd
  compressImage ? false,
  zstd,
  # Shell commands to populate the ./files directory.
  # All files in that directory are copied to the root of the FS.
  populateImageCommands ? "",
  volumeLabel,
  uuid ? "44444444-4444-4444-8888-888888888888",
  btrfs-progs,
  libfaketime,
  # NOT UPSTREAM: filesystem-level compression algorithm handed to mkfs.btrfs.
  # Set to null to get upstream's uncompressed behaviour back.
  compress ? "zstd",
}:

let
  sdClosureInfo = pkgs.buildPackages.closureInfo { rootPaths = storePaths; };
in
pkgs.stdenv.mkDerivation {
  name = "btrfs-fs.img${lib.optionalString compressImage ".zst"}";

  nativeBuildInputs = [
    btrfs-progs
    libfaketime
  ]
  ++ lib.optional compressImage zstd;

  buildCommand = ''
    ${if compressImage then "img=temp.img" else "img=$out"}

    set -x
    (
        mkdir -p ./files
        ${populateImageCommands}
    )

    mkdir -p ./rootImage/nix/store

    xargs -I % cp -a --reflink=auto % -t ./rootImage/nix/store/ < ${sdClosureInfo}/store-paths
    (
      GLOBIGNORE=".:.."
      shopt -u dotglob

      for f in ./files/*; do
          cp -a --reflink=auto -t ./rootImage/ "$f"
      done
    )

    cp ${sdClosureInfo}/registration ./rootImage/nix-path-registration

    touch $img
    # NOT UPSTREAM: --compress, and an LD_PRELOAD shim instead of upstream's
    # fakeroot. mkfs.btrfs --rootdir walks the tree with glibc's nftw(),
    # whose internal stat calls never cross the PLT — fakeroot is blind to
    # them and the image's inodes come out owned by the BUILD USER, uid 1000
    # (reproduced on x86 with fakeroot 1.37 + btrfs-progs 6.19; upstream
    # nixpkgs has the same bug). Shipped that way, uid 1000 is the kiosk
    # user on the device, systemd-tmpfiles refuses every rule with "unsafe
    # path transition / (owned by kiosk)", and first-boot provisioning
    # collapses. The shim wraps nftw itself (a PLT call) and zeroes uid/gid
    # in every callback's stat buffer, so mkfs records root ownership. An
    # LD_PRELOAD works under qemu binfmt and on native arm CI runners alike —
    # `unshare --map-root-user` would be cleaner but qemu-user cannot create
    # user namespaces (EINVAL).
    $CC -shared -fPIC -O2 -o ownershim.so ${./rootdir-owner-shim.c}
    LD_PRELOAD=$PWD/ownershim.so \
      faketime -f "1970-01-01 00:00:01" mkfs.btrfs -L ${volumeLabel} -U ${uuid} ${
        lib.optionalString (compress != null) "--compress ${compress}"
      } -r ./rootImage --shrink $img

    if ! btrfs check $img; then
      echo "--- 'btrfs check' failed for BTRFS image ---"
      return 1
    fi

    if [ ${toString compressImage} ]; then
      echo "Compressing image"
      zstd -v --no-progress ./$img -o $out
    fi
  '';
}
