# Changelog

This file is generated from [Conventional Commit](https://www.conventionalcommits.org/)
messages by [release-please](https://github.com/googleapis/release-please). New
versions are added above automatically when a release PR is merged — write clear
commit messages rather than editing released sections by hand.

Changes are grouped by commit type (Features, Bug Fixes, …). The hardware target
is the commit **scope**, so a board's changes read as e.g. `feat(rpi5):` /
`fix(x86):`; use `daemon`/`core` (or no scope) for changes that apply everywhere.

`0.2.0` is the documented starting point; automated releases begin with the next
version.

## [0.2.0] - 2026-08-04

### Summary

Baseline release of Dashboard Assistant OS — the declarative, single-purpose
Home Assistant kiosk for x86_64, Raspberry Pi 4 and Raspberry Pi 5. Includes
first-boot provisioning, the management daemon and its Home Assistant
integration (display, brightness, zoom, dark mode, rotation, pages, screenshot,
updates and sensors), in-place OTA updates, and generation rollback/recovery.
