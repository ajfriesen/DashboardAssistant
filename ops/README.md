# ops

Operational config for the Cloudflare R2 images bucket (the one the release
workflows publish to; see `.github/workflows/boards.yml`, which builds and
publishes every board's image).

## Bucket layout

Every image the workflows publish is keyed by channel and board, with the board —
`x86_64`, `rpi4`, `rpi5` — repeated in the filename so a downloaded file is still
identifiable once it's out of its folder:

```
release/<board>/dashboard-assistant-<board>-<version>.{raw,img}.zst
release/<board>/latest.{raw,img}.zst          # newest full release
pre-release/<board>/…                         # hyphened SemVer tag, e.g. v0.2.0-rc.1
dev/<board>/dashboard-assistant-<board>-<commit>.{raw,img}.zst
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
in the repo — values live in your provider and are injected as env vars only for
the duration of the command. Everything below runs from the dev shell, which
provides `secretspec` and `aws`.

## Secrets: the `kdbx` provider

A **KeePassXC database** holds the values. secretspec's `kdbx` provider reads and
writes KDBX 4 directly — there is no helper binary to install, which is why the
dev shell carries no password-manager tooling of its own.

Which database and how to unlock it are **per-machine** choices, so they live in
`~/.config/secretspec/config.toml` and not in this repository. Nothing in the
repo names a path or a credential:

```toml
[defaults]
provider = "bench-kdbx"
profile = "default"

[defaults.providers.bench-kdbx]
uri = "kdbx:/path/to/secrets.kdbx"

[defaults.providers.bench-kdbx.credentials]
password = "keyring"
```

`credentials.password = "keyring"` is the part worth understanding: the master
password is held by the **system keyring** (KWallet, gnome-keyring, …) rather
than typed per invocation or exported into a shell profile. Put it there once:

```sh
secretspec config global provider add bench-kdbx \
  "kdbx:/path/to/secrets.kdbx" --credential password=keyring
secretspec config global init -p bench-kdbx -P default   # see note below
secretspec config provider login bench-kdbx              # prompts once, stores in the keyring
```

`config global init` validates its `-p` against *backend* names, so it refuses an
alias; set `provider = "bench-kdbx"` under `[defaults]` by hand instead.
`secretspec config global show` confirms what it ended up with.

`SECRETSPEC_KDBX_PASSWORD` and `?keyfile=PATH` are the alternatives. The env var
is discouraged for interactive use; a key file on a synced filesystem replicates
the second factor to every machine that syncs, which defeats its purpose.

The database is a **local file, not a multi-writer service**. secretspec
serialises its own writes and replaces the file atomically, but do not have
KeePassXC editing the same database while `secretspec set` runs.

## Storing the values

The three R2 secrets are optional (ops-only), so set them explicitly rather than
via `check`, which only prompts for required ones:

```sh
secretspec set R2_ACCOUNT_ID
secretspec set AWS_ACCESS_KEY_ID
secretspec set AWS_SECRET_ACCESS_KEY
```

Each lands in its own entry, value in the protected `Password` field, under the
group path `secretspec / dashboard-assistant-os / default /`.

A secret that already lives somewhere else in the database is pointed at with a
`ref` in `../secretspec.toml` instead, so secretspec reads your entry rather
than making a second copy of it. `item` is the group path plus the entry title,
and `field` is any standard *or custom* field on it — which is what lets two
secrets share one entry, as the Bench Wi-Fi's do:

```toml
BENCH_WIFI_SSID = { description = "…", ref = { item = "<group>/Bench WiFi", field = "SSID" } }
BENCH_WIFI_PSK  = { description = "…", ref = { item = "<group>/Bench WiFi", field = "PSK"  } }
```

A `ref` is the one place the repo does name something about your database, so
keep it to the entry layout — never a path or a credential.

## Checking it resolves

`secretspec get` prints the value, which is rarely what you want. To confirm a
secret resolves without putting it on your terminal or in your scrollback:

```sh
secretspec run -- sh -c 'test -n "$BENCH_WIFI_PSK" && echo ok'
```

A wrong `ref` fails loudly and names what it looked for — `KDBX group ... not
found` — so a typo in a group name is a ten-second fix rather than a mystery.

## Applying the policy

```sh
secretspec run -- just r2-lifecycle-apply   # apply ops/r2-lifecycle.json
secretspec run -- just r2-lifecycle-show    # print the policy on the bucket
```

`secretspec run` resolves the declared secrets and runs the recipe with them in
the environment; `just` then invokes `aws`. The R2 S3 API token needs object +
bucket-config write on this bucket. The account id and bucket name mirror the
`R2_ACCOUNT_ID` / `R2_BUCKET` Actions variables; `R2_BUCKET` isn't secret and
defaults in the recipe.

The provider is still your machine's choice: `kdbx` is what this project
documents, and swapping it for any other secretspec backend is a change to
`~/.config/secretspec/config.toml` alone — the manifest in this repo declares
*which* secrets exist, never where they are kept.

## Agents need a reason

secretspec 0.21 records secret access to `~/.local/state/secretspec/audit.log`,
and `require_reason` in `[project]` defaults to `"agents"`. A human shell is
unaffected; an invocation it detects as an agent (Claude Code and the like sets
`CLAUDECODE` in the environment) is refused without one:

```sh
secretspec --reason "apply the R2 lifecycle policy" run -- just r2-lifecycle-apply
```

Leave that default alone. It costs a flag in automation and it is the only
record of what read your credentials.
