# Developer Documentation

## Releasing

Versioning, the changelog and GitHub Releases are automated with
[release-please](https://github.com/googleapis/release-please) driven by
[Conventional Commits](https://www.conventionalcommits.org/). You never edit the
changelog or bump the version by hand — you write good commit messages.

**Day to day:** commit with a Conventional Commit message — either straight to
`main` or on a branch you merge; release-please reads the commit history, so both
count. Examples: `feat: add rotation select`, `fix: handle missing battery`,
`docs: expand HACS steps`. The type decides the version bump:

- `feat:` → minor (0.1.0 → 0.2.0)
- `fix:` / `docs:` / `chore:` / `refactor:` / … → patch (0.1.0 → 0.1.1)
- a `!` (e.g. `feat!:`) or a `BREAKING CHANGE:` footer → major (0.1.0 → 1.0.0)

**To cut a release:** release-please keeps a single **release PR** open (titled
e.g. `chore(main): release 0.2.0`) that bumps
`custom_components/dashboard_assistant/manifest.json` and updates `CHANGELOG.md`
from the commits since the last release. Review it and **merge** — that tags
`v0.2.0`, publishes the GitHub Release, and (because the manifest was bumped in
the same commit the tag points at) HACS installs the matching version. There is
no tag to push or version to edit yourself.

Prefix a commit with `chore:`/`build:` etc. or add a `BREAKING CHANGE:` footer to
steer the bump; see the [Conventional Commits spec](https://www.conventionalcommits.org/).
A CI check validates each PR's title as a Conventional Commit (the squash-merge
message release-please reads), so a malformed title is caught before it lands.

### Create pre-release

1. Create empty commit:
```
git commit --allow-empty -m "chore: release 0.1.0-rc.3" -m "Release-As: 0.1.0-rc.3"
```
2. Push
3. Merge on GitHub

[os]: https://github.com/ajfriesen/dashboard-assistant


## How it connects

The daemon exposes `http://<device>:8081/api/ha/*`, guarded by a bearer token.
The token is generated on the device on first boot (or seeded/imported) and shown
on the on-screen Config panel. See the OS repo (`daemon/ha.go`,
`modules/core/ha-api.nix`) for the device side.
