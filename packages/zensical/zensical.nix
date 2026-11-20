# zensical — the website's static site generator, bumped past nixpkgs.
#
# nixpkgs-unstable carries 0.0.62; the website wants 0.1.x. Rather than package
# it from scratch, this overrides nixpkgs' own derivation (same PyPI sdist +
# maturin build) with a newer version. 0.1 split the theme templates and assets
# into a separate `zensical-ui` package, which nixpkgs doesn't have yet, so it
# is built here too — from its PyPI sdist, which ships the prebuilt assets, so
# no npm build is needed.
#
# Delete this file (and its uses in flake.nix) once nixpkgs' zensical reaches
# this version: `nix eval --raw .#zensical.version` vs `pkgs.zensical.version`.
{
  zensical,
  fetchPypi,
  rustPlatform,
  python3Packages,
}:

let
  zensical-ui = python3Packages.buildPythonPackage rec {
    pname = "zensical-ui";
    version = "0.0.42";
    pyproject = true;

    src = fetchPypi {
      pname = "zensical_ui";
      inherit version;
      hash = "sha256-209TK0XX+CANCNX7jnlFxp3XOO7UlBcAi4R1cqjjrI0=";
    };

    build-system = [ python3Packages.hatchling ];

    pythonImportsCheck = [ "zensical_ui" ];
  };
in
zensical.overridePythonAttrs (old: rec {
  version = "0.1.1";

  src = fetchPypi {
    inherit (old) pname;
    inherit version;
    hash = "sha256-BAXSiR3Kdqb7QvroFB26k6lfMZBRSJQKnxOIO/HM/kM=";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (old) pname;
    inherit version src;
    hash = "sha256-bse528U80zjZSXcGNpzJtJGlujCFhpPiBTcJ/vzoneg=";
  };

  # 0.1 dropped deepmerge and added pathspec and zensical-ui.
  dependencies = with python3Packages; [
    click
    jinja2
    markdown
    pathspec
    pygments
    pymdown-extensions
    pyyaml
    tomli
    zensical-ui
  ];

  passthru = (old.passthru or { }) // {
    inherit zensical-ui;
  };
})
