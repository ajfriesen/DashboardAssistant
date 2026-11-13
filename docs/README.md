# Developer Documentation

For working on Dashboard Assistant OS. Everything in this directory is for contributors and is read on GitHub; none of it is published. The public website is a separate tree, [`website/`](../website/), built with Zensical — `just website-serve` to preview it, `just website-build` to build it.

- **[`CONTEXT.md`](../CONTEXT.md)**: the project's vocabulary. Use these terms in code, commits and docs.
- **[`adr/`](adr/)**: architecture decisions and why they were made. Read the relevant one before changing something it covers.

## Layout

| Path | What |
|---|---|
| `flake.nix` | Boards, images, checks and the version release-please bumps |
| `modules/core/` | The OS: kiosk, daemon service, seeding, updates, flash wear |
| `modules/hardware/` | Per-board config and the shared disk layout (`disk-layout.nix`) |
| `modules/dev.nix` | What makes a dev image: root SSH and a root password |
| `daemon/` | Go daemon: the Home Assistant API, pairing, recovery, updates, screenshots |
| `tests/` | NixOS VM tests |
| `labgrid/` | The bench: flash and test a real Raspberry Pi 5 ([README](../labgrid/README.md)) |
| `ops/` | R2 image bucket, release channels, secrets ([README](../ops/README.md)) |
| `website/` | The public site at dashboardassistant.org: Zensical config, theme overrides and the pages in `website/content/` |

## Building and running

`just` lists every recipe. The common ones:

- `just build-disk-image` / `just build-rpi4` / `just build-rpi5`: build a board's image
- `just build-disk-image-dev` / `just build-rpi5-dev`: dev images with root SSH
- `just qemu-run`, then `just qemu-ssh`: boot the x86 image in QEMU and get a shell
- `just deploy-rpi5-dev HOST`: push the working tree to a dev Pi without reflashing
- `just options`: list the `dashboardAssistant.*` NixOS options

## Testing

- **VM tests** run in CI (`.github/workflows/vm-tests.yml`); locally with `nix build .#checks.x86_64-linux.<name>`.
- **Bench**: `just hw-test` flashes the Pi 5 dev image to the bench board and asserts first boot. The hardware hangs off the bench host and is reached through a labgrid coordinator ([ADR 0010](adr/0010-the-bench-is-driven-through-a-labgrid-coordinator.md)), so this needs non-interactive ssh to it; `just hw-status` shows the place and who holds it. There is no x86 hardware on the bench yet.

## Bumping nixpkgs

Every board builds from a pinned `nixos-unstable` ([ADR 0008](adr/0008-every-board-builds-from-pinned-nixos-unstable.md)). Bump it about once a month, on purpose:

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

**Every release starts as a candidate.** release-please keeps one release PR open and always proposes a release candidate (`release-please-config.json`: `"versioning": "prerelease"`, `"prerelease": true`). Merging the PR bumps the version in `flake.nix`, updates `CHANGELOG.md`, tags the release and uploads the images. Versions with a SemVer hyphen go to the R2 `pre-release/` channel ([ADR 0007](adr/0007-releases-come-from-commits-and-images-live-in-r2.md), [ops/README.md](../ops/README.md)).

| `main` is on | Commits since | Release PR |
|---|---|---|
| `1.2.0-rc.1` | any `fix:` or `feat:` | `1.2.0-rc.2` |
| `1.2.0` | `fix:` | `1.2.1-rc.1` |
| `1.2.0` | `feat:` | `1.3.0-rc.1` |
| `1.2.1-rc.1` | `feat:` | `1.3.0-rc.1` |

**To cut the final release:** `just release-final`. It pushes an empty `Release-As: 1.2.0` commit to `main` (it asks first), and release-please retitles its PR to `release 1.2.0`. Merge that PR. Any other version works the same way by hand:

```sh
git commit --allow-empty -m "chore: release 1.3.0-rc.1" -m "Release-As: 1.3.0-rc.1"
```

A merged release, candidate or final, is still held back from devices until the bench gate passes and it is promoted ([ADR 0011](adr/0011-a-release-is-promoted-after-the-release-gate.md)).
