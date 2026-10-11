# Releases come from commits, and images live in R2

Versions, changelogs and releases are derived from Conventional Commits by release-please (5edb99f). Images are published to an R2 bucket, split into channels by SemVer: `release/` is immutable and never expires, `pre-release/` expires after 90 days, and `dev/` (branch builds) after 7 (139fa68, 264c578, `ops/README.md`). Only a release tag may move the `latest` pointer people flash from, so `dev/` has none, and prereleases stay off the stable update path.

## Considered Options

- **GitHub Actions artifacts for images**: rejected as far too slow at these sizes (b5b8f7b, af878eb).
- **Manually pushed `v*` tags** (d0787e5): replaced by release-please.
