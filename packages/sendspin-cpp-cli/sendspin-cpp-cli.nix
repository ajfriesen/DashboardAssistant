# sendspin-cli: the Open Home Foundation's Sendspin player for Linux
# (https://github.com/Sendspin/sendspin-cpp-cli), built on the sendspin-cpp
# library. Packaged from source because it is not in nixpkgs. It replaces
# sendspin-go, whose upstream is unmaintained and whose player browsed for the
# server over its own mDNS stack: that loop leaked 2.8 GB on a device in the
# field (#16). This player advertises itself through the system's Avahi and
# waits for the server to connect in.
#
# Upstream's CMake fetches sendspin-cpp and its dependencies at configure time.
# The sandbox has no network, so each one is pinned here at the tag the
# release's CMake asks for and handed over through FETCHCONTENT_SOURCE_DIR_*,
# which is upstream's documented offline build. Bumping sendspin-cli means
# re-reading those tags: SENDSPIN_GIT_TAG in its CMakeLists.txt, the rest in
# sendspin-cpp's cmake/host.cmake.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  alsa-lib,
  libpulseaudio,
  pipewire,
  avahi-compat,
  zlib,
}:

let
  sendspin-cpp = fetchFromGitHub {
    owner = "Sendspin";
    repo = "sendspin-cpp";
    tag = "v0.10.0";
    hash = "sha256-wzrrq/oB+8IhKr0fUTynrihpFaJ5iwlAVbc6PrizMZI=";
  };
  arduinojson = fetchFromGitHub {
    owner = "bblanchon";
    repo = "ArduinoJson";
    tag = "v7.4.1";
    hash = "sha256-CvwL3FDsbQGLkZFC3Z/RWeiT9tO+7ZRpT65YUdRT5dQ=";
  };
  # Both carry their codecs as git submodules (libopus, an Ogg demuxer).
  micro-flac = fetchFromGitHub {
    owner = "esphome-libs";
    repo = "micro-flac";
    tag = "v0.3.1";
    fetchSubmodules = true;
    hash = "sha256-mKpQA5ohvL4rAL5ZtXXCUT42UEy73ec2NWlQcomPzbA=";
  };
  micro-opus = fetchFromGitHub {
    owner = "esphome-libs";
    repo = "micro-opus";
    tag = "v0.3.5";
    fetchSubmodules = true;
    hash = "sha256-OV5J8UgL81Rerotu2zjpR5LQfqnYb0e+KkFutP1INqo=";
  };
  ixwebsocket = fetchFromGitHub {
    owner = "machinezone";
    repo = "IXWebSocket";
    tag = "v12.0.1";
    hash = "sha256-2QWIpLVIs2vGuMEhewDyihYdDQBz7SsOtfZ6pE67j2Q=";
  };
  noise-c = fetchFromGitHub {
    owner = "esphome-libs";
    repo = "noise-c";
    tag = "v0.1.13";
    hash = "sha256-5bu3Vh+8w4cVuU9n7oc20uhswJgxVtIeHoIzTjAr/Xo=";
  };

  deps = [
    {
      name = "sendspin";
      var = "SENDSPIN";
      src = sendspin-cpp;
    }
    {
      name = "arduinojson";
      var = "ARDUINOJSON";
      src = arduinojson;
    }
    {
      name = "micro-flac";
      var = "MICRO_FLAC";
      src = micro-flac;
    }
    {
      name = "micro-opus";
      var = "MICRO_OPUS";
      src = micro-opus;
    }
    {
      name = "ixwebsocket";
      var = "IXWEBSOCKET";
      src = ixwebsocket;
    }
    {
      name = "noise-c";
      var = "NOISE_C";
      src = noise-c;
    }
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "sendspin-cli";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "Sendspin";
    repo = "sendspin-cpp-cli";
    tag = "v${finalAttrs.version}";
    hash = "sha256-CRLCL9yfBxtWeXH7hvYoEr9IClS2tLojHyjUCqG1tCI=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
  ];

  # PipeWire is the backend the device uses (modules/core/sendspin.nix); ALSA
  # and Pulse come along because they are free and each is a fallback when a
  # board's sound misbehaves. PortAudio adds nothing over those on Linux.
  buildInputs = [
    alsa-lib
    libpulseaudio
    pipewire
    avahi-compat
    zlib
  ];

  # micro-opus stages libopus with configure_file, which copies the source's
  # read-only store permissions and then fails to overwrite its own copy. So
  # every dependency is handed over as a writable copy, not its store path.
  preConfigure = ''
    deps=$NIX_BUILD_TOP/deps
    mkdir -p "$deps"
    ${lib.concatMapStrings (d: ''
      cp -r --no-preserve=mode ${d.src} "$deps/${d.name}"
      cmakeFlagsArray+=("-DFETCHCONTENT_SOURCE_DIR_${d.var}=$deps/${d.name}")
    '') deps}
  '';

  cmakeFlags = [
    (lib.cmakeBool "FETCHCONTENT_FULLYDISCONNECTED" true)
    (lib.cmakeBool "SENDSPIN_CLI_BUILD_TESTS" false)
    (lib.cmakeBool "SENDSPIN_CLI_WITH_PORTAUDIO" false)
    # The `tui` subcommand (FTXUI) is for a person at a terminal; a device has none.
    (lib.cmakeBool "SENDSPIN_CLI_WITH_TUI" false)
    # Avahi's dns_sd.h lives in a subdirectory find_path does not search.
    (lib.cmakeFeature "SENDSPIN_CLI_DNS_SD_INCLUDE_DIR" "${lib.getDev avahi-compat}/include/avahi-compat-libdns_sd")
  ];

  # The vendored libraries install their headers and CMake files alongside the
  # binary. Upstream's systemd unit and sysusers file go too: the module writes
  # its own unit.
  postInstall = ''
    rm -rf $out/include $out/lib $out/share/ArduinoJson $out/share/systemd
  '';

  meta = {
    description = "Headless synchronized multi-room audio player for the Sendspin protocol";
    homepage = "https://github.com/Sendspin/sendspin-cpp-cli";
    license = lib.licenses.asl20;
    mainProgram = "sendspin-cli";
    platforms = lib.platforms.linux;
  };
})
