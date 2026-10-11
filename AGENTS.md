# Agent instructions

Dashboard Assistant OS: a NixOS image that turns a mini-PC or Raspberry Pi into a Home Assistant dashboard. Start with [`developer/README.md`](developer/README.md) for the layout, build and test commands.

- **Vocabulary**: use the terms in [`CONTEXT.md`](CONTEXT.md) in code, comments, commits and docs, and avoid the words it lists under _Avoid_. For example, say device, not tablet; seeding, not import.
- **Decisions**: before changing anything an ADR in [`docs/adr/`](docs/adr/) covers, read it. Don't "fix" deliberate choices. An ADR with `status: proposed` describes intended behaviour that isn't implemented yet; the code is the current truth.
- **Commits**: Conventional Commits, because release-please derives versions and the changelog from them (`feat:`, `fix:`, `docs:`, … with a scope such as `fix(core):`).
- **Docs**: `docs/` is the user-facing site (Zensical, explicit `nav` in `zensical.toml`). ADRs live in `docs/adr/` and are published but not in the nav; other developer docs stay in `developer/` as plain Markdown.
