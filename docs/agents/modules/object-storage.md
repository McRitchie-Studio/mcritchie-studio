# Object Storage — S3 buckets, keys, and conventions

## Status: Active

Steffon owns this module. Mr. McRitchie approved the rules on 2026-09-01 and
handed maintenance to Steffon's role: rule changes ride normal doc tasks under
his name, and `bucket-provision`
([`../agents/steffon/sops/bucket-provision.md`](../agents/steffon/sops/bucket-provision.md))
is the act that applies them to a new app.

## The rules

| Rule | Standard |
|---|---|
| Buckets per app | `<app>-dev` + `<app>-production`; provisioning is opt-in at app creation — a silly little app can decline |
| Region | `us-east-2` — the fleet's home; do not scatter |
| Write routing | prod app → production bucket; **QA and local → dev bucket** |
| Read routing | QA/local may read prod — enforced by IAM, never by app discipline |
| App credentials | two IAM users per app under path `/mcr/`: `mcr-<app>-prod` (RW its production bucket) and `mcr-<app>-dev` (RW its dev bucket + **read-only** its production bucket). QA runs the dev credential |
| Public access | private by default: Block Public Access all-on, no bucket policy. Public serving is an explicit, documented exception (see **Legacy posture**) |
| Private assets | served through app auth via presigned URLs (~15-min GET). Any key with `s3:GetObject` can presign; no extra permission exists |
| Versioning | ON for production buckets (an errant overwrite or delete is recoverable); dev unversioned |
| Lifecycle | **design pending** — dev buckets carry seed assets apps still serve, so a blanket dev expiry would break local stacks. Do not add lifecycle rules ad hoc |
| Encryption | SSE-S3 (AES256, the account default). Buckets are `bucket-owner-enforced`: ACLs are disabled, `put_object(acl: …)` raises — grant reads through bucket policy or presigned URLs, never per-object ACLs |
| Tags | `app`, `env`, `entity` on every bucket — the cost lines |
| Code discipline | S3 writes fail loudly. Never wrap an upload in a rescue that returns success — a QA lane once shared prod's bucket with no credentials and its writes failed silently for weeks |
| URL style | path-style (`https://s3.us-east-2.amazonaws.com/<bucket>/<key>`); the virtual-hosted host trips Chrome's lookalike-domain interstitial against `mcritchie.studio` |

## The credential tiers

| Tier | Identity | Holds | Store |
|---|---|---|---|
| 1 | `alex-admin` / root | Mr. McRitchie only | his private vault |
| 2 | `studio-agents-admin` | Steffon's provisioning lane: `s3:*`, mint/rotate `/mcr/*` users, account read-only | item `AWS`, vault `studio-agents-admin` (admin op lane only) |
| 3 | `agent-studio` | day-to-day agent object surgery across the fleet; no IAM, no bucket create/delete | **design pending** — nothing mints it yet, `bucket-provision` included; until it exists, use tier 2 or the app's tier-4 key |
| 4 | `mcr-<app>-prod` / `mcr-<app>-dev` | one app's buckets, exactly | Heroku config vars + 1Password record |

A credential belongs to exactly one kind of principal. Apps never borrow agent
keys; agents never borrow app keys.

Reading tier 2 (the only lane this module's procedures need):

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
export AWS_ACCESS_KEY_ID=$(op item get AWS --vault studio-agents-admin --fields label=access-key --reveal)
export AWS_SECRET_ACCESS_KEY=$(op item get AWS --vault studio-agents-admin --fields label=secret-access-key --reveal)
export AWS_DEFAULT_REGION=us-east-2
```

The ordinary agent token cannot list the `studio-agents-admin` vault — that
invisibility is the design
([`credential-inventory.md`](credential-inventory.md)). The admin service
account's grant is read-only: `op item get` works, `op item edit` is refused.

**Guards, stated honestly.** `studio-agents-admin` sits outside the `/mcr/` IAM path,
so it cannot edit its own policy — policy changes are an operator console
paste. It CAN write arbitrary inline policies onto the `/mcr/*` users it
mints, so a compromised tier 2 could mint an over-privileged user; the sealed
fix is an IAM permissions boundary, filed as OPSEC backlog, not ceremony.

## Fleet census — 2026-09-01, post-remediation

| Bucket | Region | Public read | Versioned | Notes |
|---|---|---|---|---|
| `mcritchie-studio-production` | us-east-2 | **yes — legacy** | yes | Active Storage + public assets |
| `mcritchie-studio-dev` | us-east-2 | **yes — legacy** | no | has `archive-after-90-days` lifecycle |
| `turf-monster-production` | us-east-2 | **yes — legacy** | yes | |
| `turf-monster-dev` | us-east-2 | **yes — legacy** | no | |
| `mcritchie-industries-production` | us-east-2 | no (flipped 2026-09-01) | yes | knowledge-layer destination; was world-readable while empty |
| `mcritchie-industries-dev` | us-east-2 | no (flipped 2026-09-01) | no | |
| `commercial-welding-production` | us-east-2 | no | yes | recreated 2026-09-01 from us-east-1 |
| `commercial-welding-dev` | us-east-2 | no | no | recreated 2026-09-01 from us-east-1 |
| `moms-app-production` | us-east-2 | no | yes | was the fleet's one private bucket all along |

Re-derive before trusting: `aws s3api get-bucket-policy` /
`get-public-access-block` / `get-bucket-versioning` per bucket — a census is
only true for the day it was taken.

## Legacy posture — what the rules do NOT yet cover

- **Shared app identity.** One IAM user, `mcritchie-s3` (item `agent.aws`),
  still backs Active Storage for every deployed app. The per-app tier-4 users
  are the successor; migration is ladder work, one app per task, coordinated
  with that app's config vars. Blast radius and rotation choreography:
  [`credential-inventory.md`](credential-inventory.md) **Shared AWS identity**.
- **Public-read buckets.** The four studio/turf buckets keep
  `PublicReadGetObject` because deployed apps serve raw object URLs from them.
  Removing it is app work (CDN or public-prefix migration — see
  [`../system/cdn-rollout.md`](../system/cdn-rollout.md)), not a console flip;
  on those buckets `public: false` in `storage.yml` is NOT a privacy control.
- **Industries QA — credentials RESOLVED 2026-09-02; bucket cutover OPEN.**
  Industries became the first app on tier-4 credentials:
  `mcr-mcritchie-industries-{prod,dev}` were minted under `/mcr/` by
  `bucket-provision`'s first live run, the routing law was proven by refusal
  (the dev key's write to the production bucket was rejected by IAM), and both
  Heroku apps carry their vars (prod key on `mcritchie-industries`, dev key on
  `mcritchie-industries-qa`). Still open: `QA_ENV` is unset on
  `mcritchie-industries-qa`, so its `storage.yml` resolves the PRODUCTION
  bucket — which its dev key cannot write (the same routing law, now refusing
  QA's own uploads). Tracked at `/tasks/industries-qa-bucket-cutover`. The
  1Password record (`agent.mcritchie-industries.aws`, `industries-agents`
  vault) is owed by a write-capable lane — values live in Heroku config until
  it lands.
