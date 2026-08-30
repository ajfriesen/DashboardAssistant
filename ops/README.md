# ops

Operational config for the Cloudflare R2 images bucket (the one the release
workflows publish to; see `.github/workflows/release-image.yml` and
`cache-rpi.yml`).

## Bucket layout

Every image the workflows publish is keyed by channel and arch, with the arch —
`x86_64`, `rpi4`, `rpi5` — repeated in the filename so a downloaded file is still
identifiable once it's out of its folder:

```
release/<arch>/dashboard-assistant-<arch>-<version>.{raw,img}.zst
release/<arch>/latest.{raw,img}.zst          # newest full release
pre-release/<arch>/…                         # hyphened SemVer tag, e.g. v0.2.0-rc.1
dev/<arch>/dashboard-assistant-<arch>-<commit>.{raw,img}.zst
```

`dev/` holds branch builds (`.raw.zst` on x86_64, `.img.zst` on the Pis), keyed by
the short commit and with no `latest` pointer — nothing outside a release tag may
become the image people flash. Images are never attached to the Actions run
itself; GitHub artifacts are far too slow at these sizes.

## `r2-lifecycle.json`

The bucket's object-lifecycle policy, tracked here so it's reviewable and applied
declaratively rather than clicked together in the dashboard. R2 implements the S3
`PutBucketLifecycleConfiguration` API, so `aws s3api` applies it directly.

Current rules:

| Rule | Prefix | Effect |
|---|---|---|
| `abort-incomplete-multipart-uploads` | (all) | Abort stalled multipart uploads after 3 days (big images upload multipart). |
| `expire-dev` | `dev/` | Delete after 7 days — branch builds are throwaway, and one lands per manual run. |
| `expire-development` | `development/` | Delete after 7 days. The old name for `dev/`; nothing publishes here anymore, this just sweeps strays. |
| `expire-pre-releases` | `pre-release/` | Delete after 90 days — prereleases are transient. |

`release/**` has **no** rule: released images are immutable and kept indefinitely.

## Applying it

Credentials come from [secretspec](https://secretspec.dev) (declared in
`../secretspec.toml`), so nothing sensitive is typed on the command line or kept
in the repo — values live in your provider (e.g. `pass`/GPG) and are injected as
env vars only for the duration of the command. Everything below runs from the dev
shell, which provides `secretspec`, `aws`, `pass` and `gnupg`.

One-time setup with the `pass` provider:

```sh
# 1. A GPG key + an initialised pass store: pass init <your-gpg-id>
# 2. Point secretspec at the pass provider (writes ~/.config/secretspec/config.toml):
secretspec config init            # pick "pass"
# 3. Store the values (prompts, encrypted into pass). They're optional (ops-only),
#    so set them explicitly rather than via `check`:
secretspec set R2_ACCOUNT_ID
secretspec set AWS_ACCESS_KEY_ID
secretspec set AWS_SECRET_ACCESS_KEY
```

Then apply / inspect the policy:

```sh
secretspec run -- just r2-lifecycle-apply   # apply ops/r2-lifecycle.json
secretspec run -- just r2-lifecycle-show    # print the policy on the bucket
```

`secretspec run` resolves the declared secrets and runs the recipe with them in
the environment; `just` then invokes `aws`. The R2 S3 API token needs object +
bucket-config write on this bucket. The account id and bucket name mirror the
`R2_ACCOUNT_ID` / `R2_BUCKET` Actions variables; `R2_BUCKET` isn't secret and
defaults in the recipe. The provider is your machine's choice — swap `pass` for
any secretspec backend via `secretspec config init` without touching the repo.
