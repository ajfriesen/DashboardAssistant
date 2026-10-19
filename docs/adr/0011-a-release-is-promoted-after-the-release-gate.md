---
status: proposed
---

# A release is promoted after the release gate, not published green

Tagging a release publishes images; it does not prove any of them boot. So a tag now produces a **candidate**: the per-version images go to R2 as they always did, but the GitHub release is not marked latest and its notes carry no download links. The **release gate** then runs on the **bench**, and a green run is what unlocks **promotion** — a job behind a protected environment that marks the release latest and writes the links.

The gate runs from a maintainer's machine rather than from a workflow, because the bench is physical and hangs off the **bench host** ([0010](0010-the-bench-is-driven-through-a-labgrid-coordinator.md)); there is no self-hosted runner yet. The gate posts a commit status on the candidate's commit, so the mechanism that promotion waits on is the same one a runner would post later.

## Considered Options

Gating a release-candidate tag and then cutting the final tag was the obvious alternative, and it fails on a technicality that matters: the version string is baked into the images, so the final release is not the artifact the gate booted. Promoting after the fact is the only arrangement where the bytes a **device** installs are the bytes a test flashed. Release-candidate tags keep their existing job of early access; they are not part of the gate.

## Consequences

- A published release that is not the latest one is deliberate. It is a candidate that has not passed, or not yet run.
- `/repos/<repo>/releases/latest` is the lever that matters, because that is what `modules/core/update.nix` polls — it is the only pointer that reaches devices already in use, with no human involved. Promotion is two `gh` calls and moves no images.
- R2's `release/<board>/latest.raw.zst` is dropped. It only duplicated the notes table, and keeping two pointers in step across a gate buys nothing.
- The notes get their download links at promotion, so the releases page cannot hand out an unpromoted image either.
- Nothing in the gate retries. A failure has to mean the image, which is why the suite begins with a preflight that fails as a *bench* fault — an unhealthy bench has misreported itself as a code problem here before.
- A candidate that fails is never promoted and never deleted. Its per-version images stay downloadable, so the failure stays reproducible.
- When a self-hosted runner arrives, the required reviewer becomes a `needs:` on the hardware job and nothing else in the pipeline changes.
