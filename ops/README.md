# ops

Operational config for the Cloudflare R2 images bucket (the one the release
workflows publish to; see `.github/workflows/release-image.yml` and
`cache-rpi.yml`).

## `r2-lifecycle.json`

The bucket's object-lifecycle policy, tracked here so it's reviewable and applied
declaratively rather than clicked together in the dashboard. R2 implements the S3
`PutBucketLifecycleConfiguration` API, so `aws s3api` applies it directly.

Current rules:

| Rule | Prefix | Effect |
|---|---|---|
| `abort-incomplete-multipart-uploads` | (all) | Abort stalled multipart uploads after 3 days (big images upload multipart). |
| `expire-development` | `development/` | Delete after 7 days. Nothing publishes here anymore; this just sweeps strays. |
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
# 3. Store the values (prompts, encrypted into pass). `check` fills any missing:
secretspec check                  # or: secretspec set R2_ACCOUNT_ID, etc.
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
