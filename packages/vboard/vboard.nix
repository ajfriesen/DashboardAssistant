# vboard — a GTK3 on-screen keyboard, packaged from source because it is not in
# nixpkgs. It injects keystrokes via /dev/uinput (kernel level, so it works
# under any compositor including Sway) and, crucially for a kiosk, marks its
# window non-focusable (set_accept_focus/can_focus false) so the injected keys
# land in whatever is actually focused (Chromium), not the keyboard itself.
#
# It is a Meson project that installs a thin `vboard` launcher into bin/ and the
# real Python package under share/vboard/vboard; the launcher adds
# ../share/vboard to sys.path. We point its shebang at a Python that has
# PyGObject + python-uinput, and wrapGAppsHook3 supplies the GI typelibs (Gtk,
# Gdk, AyatanaAppIndicator3) and icon/schema paths at runtime.
{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  wrapGAppsHook3,
  gobject-introspection,
  glib,
  gtk3,
  gdk-pixbuf,
  librsvg,
  libayatana-appindicator,
  python3,
  jq,
}:

let
  pythonEnv = python3.withPackages (ps: [
    ps.pygobject3
    ps.pycairo
    ps.python-uinput
  ]);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "vboard";
  version = "2.7.0";

  src = fetchFromGitHub {
    owner = "archisman-panigrahi";
    repo = "vboard";
    rev = "v${finalAttrs.version}";
    hash = "sha256-Pl3xLzaFscLX7myOqE/hIvfYwIy5NbfxN2Ur4K1f3nc=";
  };

  # Nix installs meson projects straight into $out (no DESTDIR), so the upstream
  # post-install hook's DESTDIR guard never fires and it would run
  # gtk-update-icon-cache / update-desktop-database / KDE cache refresh against
  # the store. None of that is needed here, so neuter it to a no-op.
  postPatch = ''
    printf '#!/bin/sh\nexit 0\n' > scripts/meson-post-install.sh

    # Make the key-label font size env-tunable (VBOARD_FONT_PX, default the
    # upstream 19). The homogeneous key grid's minimum width is set by the
    # word-labeled modifier keys at this font size — ~900px at 19px — which
    # overflows a 600px-wide portrait output, and the size is a CSS *pixel*
    # value inside an f-string at STYLE_PROVIDER_PRIORITY_USER, so neither
    # GDK_DPI_SCALE (points only) nor user gtk.css can shrink it from outside.
    # The kiosk's OSK toggle sets VBOARD_FONT_PX on narrow outputs.
    substituteInPlace vboard/window.py \
      --replace-fail 'font-size: 19px;' 'font-size: {int(os.environ.get("VBOARD_FONT_PX", "19"))}px;'

    # No links out of the keyboard. Since 2.6 its on-screen Options dialog
    # (☰ → Options) has "Report bugs", which opens the issue tracker in the
    # default browser, and "About", whose dialog links to the homepage. On a
    # kiosk either would hand a guest a browser window outside the dashboard.
    # The buttons stay; they just open nothing.
    substituteInPlace vboard/window.py \
      --replace-fail 'Gio.AppInfo.launch_default_for_uri(BUG_REPORT_URL, None)' 'pass' \
      --replace-fail 'about_dialog.set_website("https://github.com/archisman-panigrahi/vboard")' 'pass' \
      --replace-fail 'about_dialog.set_website_label("Homepage")' 'pass'

    # Make the default layout env-tunable (VBOARD_LAYOUT, default the upstream
    # "en"). The kiosk deletes settings.conf before every launch, and vboard only
    # reads a layout from it alongside its colour settings, so the default is
    # the one place the kiosk can set it. The kiosk sets it from the device
    # locale, matching Sway's keyboard layout (kiosk.nix, regionEnv).
    substituteInPlace vboard/constants.py \
      --replace-fail 'DEFAULT_KEYBOARD_LAYOUT = "en"' 'DEFAULT_KEYBOARD_LAYOUT = __import__("os").environ.get("VBOARD_LAYOUT", "en")'

    # Upstream's French layout labels the bottom row one key off from AZERTY:
    # no key shows "w" (xkb fr types it from Z), and M , . / show what the key
    # to their right types. xkb fr also has nothing on Shift+². Relabel them to
    # what xkb fr types, which the vboard-layouts check verifies key by key.
    jq '.labels += {"Z": "w", "M": ",", ",": ";", ".": ":", "/": "!"}
      | .shifted += {"M": "?", ",": ".", ".": "/", "/": "§"}
      | del(.shifted["`"])' vboard/layouts/fr.json > fr.json
    mv fr.json vboard/layouts/fr.json
  '';

  nativeBuildInputs = [
    jq
    meson
    ninja
    pkg-config
    wrapGAppsHook3
    gobject-introspection
  ];

  buildInputs = [
    glib
    gtk3
    gdk-pixbuf
    librsvg
    libayatana-appindicator
    pythonEnv
  ];

  # The launcher is installed with a `/usr/bin/env python3` shebang; repoint it
  # at the interpreter that actually has PyGObject + python-uinput. wrapGAppsHook3
  # then wraps it for the GI typelibs and icon/schema paths.
  postInstall = ''
    substituteInPlace $out/bin/vboard \
      --replace-fail '#!/usr/bin/env python3' '#!${pythonEnv.interpreter}'
  '';

  meta = {
    description = "Customizable on-screen keyboard for Linux (uinput injection)";
    homepage = "https://github.com/archisman-panigrahi/vboard";
    license = lib.licenses.gpl3Plus;
    mainProgram = "vboard";
    platforms = lib.platforms.linux;
  };
})
