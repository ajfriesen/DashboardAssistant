# Developer Documentation

For working on Dashboard Assistant OS. User-facing docs live in `docs/` and are published with Zensical.

- **[`CONTEXT.md`](../CONTEXT.md)**: the project's vocabulary. Use these terms in code, commits and docs.
- **[`docs/adr/`](../docs/adr/)**: architecture decisions and why they were made. Read the relevant one before changing something it covers.

## Layout

| Path | What |
|---|---|
| `flake.nix` | Boards, images, checks and the version release-please bumps |
| `modules/core/` | The OS: kiosk, daemon service, seeding, updates, flash wear, admin page |
| `modules/hardware/` | Per-board config and the shared disk layout (`disk-layout.nix`) |
| `modules/dev.nix` | What makes a dev image: root SSH and a root password |
| `daemon/` | Go daemon: the Home Assistant API, pairing, admin page, updates, screenshots |
| `tests/` | NixOS VM tests |
| `labgrid/` | The bench: flash and test a real Raspberry Pi 5 ([README](../labgrid/README.md)) |
| `ops/` | R2 image bucket, release channels, secrets ([README](../ops/README.md)) |

## Building and running

`just` lists every recipe. The common ones:

- `just build-disk-image` / `just build-rpi4` / `just build-rpi5`: build a board's image
- `just build-disk-image-dev` / `just build-rpi5-dev`: dev images with root SSH
- `just qemu-run`, then `just qemu-ssh`: boot the x86 image in QEMU and get a shell
- `just deploy-rpi5-dev HOST`: push the working tree to a dev Pi without reflashing
- `just options`: list the `dashboardAssistant.*` NixOS options

## Testing

- **VM tests** run in CI (`.github/workflows/vm-tests.yml`); locally with `nix build .#checks.x86_64-linux.<name>`.
- **Bench**: `just hw-test` flashes the Pi 5 dev image to the bench board and asserts first boot. `just hw-status` shows what's connected. There is no x86 hardware on the bench yet.

## Bumping nixpkgs

Every board builds from a pinned `nixos-unstable` ([ADR 0008](../docs/adr/0008-every-board-builds-from-pinned-nixos-unstable.md)). Bump it about once a month, on purpose:

1. On a branch: `nix flake update nixpkgs-unstable`
2. VM tests green in CI, and `just hw-test` green on the bench
3. Cut a pre-release (see below)
4. Run the pre-release on a real x86 device for a few days
5. Merge

## Releasing

Versioning, the changelog and GitHub Releases are automated with [release-please](https://github.com/googleapis/release-please), driven by [Conventional Commits](https://www.conventionalcommits.org/). Never edit the changelog or bump the version by hand. Write good commit messages instead. A CI check validates each PR title as a Conventional Commit, since the squash-merge message is what release-please reads.

The commit type decides the version bump:

- `feat:` → minor
- `fix:` / `docs:` / `chore:` / `refactor:` / … → patch
- `feat!:` or a `BREAKING CHANGE:` footer → major

**To cut a release:** release-please keeps one release PR open (e.g. `chore(main): release 1.1.0`). It bumps the version in `flake.nix` and updates `CHANGELOG.md`. Merging it tags the release, publishes the GitHub Release and uploads the x86_64 image to the R2 `release/` channel ([ADR 0007](../docs/adr/0007-releases-come-from-commits-and-images-live-in-r2.md), [ops/README.md](../ops/README.md)).

**To cut a pre-release:**

```sh
git commit --allow-empty -m "chore: release 1.1.0-rc.1" -m "Release-As: 1.1.0-rc.1"
```

Push it, then merge the release PR on GitHub. Versions with a SemVer hyphen go to the `pre-release/` channel.
