# sendspin-player — the Sendspin protocol client (https://sendspin-audio.com),
# packaged from source because it is not in nixpkgs. Sendspin is the Open Home
# Foundation's multi-room audio standard: a *server* (Music Assistant) sources
# the music and streams it to *players* like this one, which stay in sync to
# well under a millisecond. The device is only ever a player, so the sibling
# `sendspin-server` binary in the same repo is deliberately not built here.
#
# Two upstream build details drive the odd bits below:
#
#   * gopkg.in/hraban/opus.v2 links libopusfile unless built with the
#     `nolibopusfile` tag. Only its opus.Stream API needs opusfile and the
#     player never calls it, so the tag drops a runtime dependency for free.
#     Upstream's Makefile sets the same tag; buildGoModule ignores Makefiles,
#     hence `tags` here.
#
#   * The audio output goes through malgo → miniaudio, which does not link
#     libasound/libpulse at build time: it dlopen()s them at *runtime* by
#     SONAME. Nothing lands in the RPATH, so on NixOS the player would start,
#     find no backend and die. The wrapper puts both on LD_LIBRARY_PATH.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  pkg-config,
  libopus,
  alsa-lib,
  libpulseaudio,
  makeWrapper,
}:

buildGoModule (finalAttrs: {
  pname = "sendspin-player";
  version = "1.8.2";

  src = fetchFromGitHub {
    owner = "Sendspin";
    repo = "sendspin-go";
    tag = "v${finalAttrs.version}";
    hash = "sha256-CRo5OrcrB6ih07DcN7ofFOMb1FwzyxqFM9ksboxp+VI=";
  };

  vendorHash = "sha256-QAmC6bgOSlV8we9j3rDQ9V3sLdSvELu8zzn5UAw/uIY=";

  # The player is the module root; ./cmd/sendspin-server is the source-side
  # counterpart we do not ship.
  subPackages = [ "." ];

  tags = [ "nolibopusfile" ];

  # Mirrors upstream's Makefile: the version shows up in the mDNS advertisement
  # and in the player's Music Assistant device info.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/Sendspin/sendspin-go/internal/version.Version=v${finalAttrs.version}"
  ];

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];
  buildInputs = [ libopus ];

  # buildGoModule names the binary after the module path's last element.
  postInstall = ''
    mv $out/bin/sendspin-go $out/bin/sendspin-player
    wrapProgram $out/bin/sendspin-player \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          alsa-lib
          libpulseaudio
        ]
      }
  '';

  # Upstream's suite spins up real servers on localhost and reaches for the
  # network in places; the build sandbox has neither.
  doCheck = false;

  meta = {
    description = "Synchronized multi-room audio player for the Sendspin protocol";
    homepage = "https://github.com/Sendspin/sendspin-go";
    license = lib.licenses.asl20;
    mainProgram = "sendspin-player";
    platforms = lib.platforms.linux;
  };
})
