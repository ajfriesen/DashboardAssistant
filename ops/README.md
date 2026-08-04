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

From the dev shell (which provides `awscli2`), with R2 S3 credentials in the
environment:

```sh
export R2_ACCOUNT_ID=<cloudflare-account-id>
export R2_BUCKET=dashboard-assistant            # optional; this is the default
export AWS_ACCESS_KEY_ID=<r2-s3-token-id>
export AWS_SECRET_ACCESS_KEY=<r2-s3-token-secret>

just r2-lifecycle-apply   # apply ops/r2-lifecycle.json
just r2-lifecycle-show    # print the policy currently on the bucket
```

The R2 S3 API token needs object + bucket-config write on this bucket. The
account id and bucket name mirror the `R2_ACCOUNT_ID` / `R2_BUCKET` Actions
variables.
