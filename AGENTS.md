# Agent instructions

Dashboard Assistant OS: a NixOS image that turns a mini-PC or Raspberry Pi into a Home Assistant dashboard. Start with [`docs/README.md`](docs/README.md) for the layout, build and test commands.

- **Vocabulary**: use the terms in [`CONTEXT.md`](CONTEXT.md) in code, comments, commits and docs, and avoid the words it lists under _Avoid_. For example, say device, not tablet; seeding, not import.
- **Decisions**: before changing anything an ADR in [`docs/adr/`](docs/adr/) covers, read it. Don't "fix" deliberate choices. An ADR with `status: proposed` describes intended behaviour that isn't implemented yet; the code is the current truth.
- **Commits**: Conventional Commits, because release-please derives versions and the changelog from them (`feat:`, `fix:`, `docs:`, … with a scope such as `fix(core):`).
- **Docs**: two trees, and nothing crosses between them. `website/` is the public **website** (a self-contained Zensical project: `website/zensical.toml`, pages in `website/content/`, explicit `nav`) — `just website-serve` previews it. `docs/` is the **developer docs**: the contributor guide, ADRs in `docs/adr/` and agent skills in `docs/agents/`, plain Markdown read on GitHub and never published. A user-facing page belongs in `website/content/`, never in `docs/`.

## Agent skills

### Issue tracker

GitHub Issues on ajfriesen/DashboardAssistant, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default roles: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` at the root, ADRs in `docs/adr/`. See `docs/agents/domain.md`.
