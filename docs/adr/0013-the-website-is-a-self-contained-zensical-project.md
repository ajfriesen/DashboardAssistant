# The website is a self-contained Zensical project in website/

The **website** lives in `website/`: `website/zensical.toml`, the theme overrides it points at, and the pages and assets in `website/content/`. Everything in `docs/` is **developer docs** — the contributor guide, the ADRs and the agent skills — read on GitHub and never published. A user-facing page belongs in `website/content/`; nothing in `docs/` is served to anyone.

Before this, one `docs/` directory held both, with `zensical.toml` at the repository root. Zensical publishes every Markdown file under its content directory whether or not the file appears in `nav`, so all twelve ADRs and all three agent-skill documents were live at `dashboardassistant.org/adr/…` and `/agents/…` — reachable, unlinked, and written for contributors rather than users. The split is what makes "is this published?" answerable from the path alone.

## Considered Options

Keeping `zensical.toml` at the root and pointing `docs_dir` at `website/` is the smaller change — one config line, no file moves beyond the content itself. It was rejected because it leaves the site's configuration and its theme overrides sitting at the repository root, two directories away from the pages they govern, while the root keeps accumulating tool config. A self-contained project is worth the `working-directory: website` in `.github/workflows/docs.yml` and the two `just` recipes that encapsulate the `cd`.

The content directory is `content/`, not Zensical's default `docs/`. `website/docs/` would have cost no config line and re-created the exact ambiguity this ADR removes: `docs/` meaning the public site in one place and the developer docs in another. One word, one meaning, at the price of `docs_dir = "content"`.

## Consequences

- Every public URL is unchanged. Zensical derives them from the path *relative to* the content directory, so renaming the content root moved no page: the build produces the same 61 files at the same paths as before.
- `dashboardassistant.org/adr/*` and `/agents/*` now 404. Nothing on the site ever linked to them and they were absent from `nav`, but inbound links from outside the site break. The ADRs are readable on GitHub, which renders this format.
- `zensical serve` and `zensical build` fail from the repository root — they only look for a config file in the current directory. `just website-serve` and `just website-build` are the supported entry points, and both `cd website` for exactly this reason.
- `website/site/` and `website/.cache/` are the build output and cache, because both are created beside the config file. They are gitignored at those paths.
- `modules/core/kiosk.nix` reaches into `website/content/brand/` for the sponsor button artwork, so the OS build depends on a path inside the website. That is deliberate — it is what stops the on-screen mark drifting from the published one — but it means moving brand assets again breaks an image build, not just a page.
- CI filters are one path each: `website/**` triggers the Pages deploy, and `boards.yml` ignores both `website/**` and `docs/**` so neither a page edit nor an ADR warms the board cache.
