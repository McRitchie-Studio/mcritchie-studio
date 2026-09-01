# Credential Inventory

This file names credential locations so agents can ask for or reference the right item without searching vaults. It must never contain secret values.

## Vaults

| Vault | Purpose |
|-------|---------|
| `agents-studio` | The **agent** vault — every build, review, and QA lane reads it through `OP_SERVICE_ACCOUNT_TOKEN`. It is the vault formerly named `agents` (renamed 2026-08-28; same vault id `txqp6ijdo3ujsfhsfzdj5h5dzq`). |
| `agents-admin` | The **admin** vault — `github.mcritchie-deployer` and other ship-lane credentials. Read only by a SEPARATE service account (`OP_ADMIN_SERVICE_ACCOUNT_TOKEN`, sourced from `~/.zprofile.admin`); the agent token is never granted it, so an ordinary agent shell cannot even list it. That invisibility is the design, not a fault. |
| `agents-industries` | Industries-brand agent credentials. Created 2026-08-28. **Not visible to the agent service account** — on 2026-08-29 `op vault list` returned `agents-studio` alone. Grant it before a lane depends on it. |
| `agents-mcritchie-family` | Family-brand agent credentials. Created 2026-08-28. **Not visible to the agent service account** — same as above. Grant it before a lane depends on it. |
| `Commercial Welding` | Reserved for the Commercial Welding initiative. Created 2026-08-28. **Not visible to the agent service account** — same as above. Grant it before a lane depends on it. |
| `Blockchain` / `🧱 Blockchain` | Human-controlled blockchain credentials, if granted. |

`bin/lib/op_vaults.rb` is the one place code names a vault (`MCR_OP_VAULT_AGENT` /
`MCR_OP_VAULT_ADMIN` override it per machine). The names in this table are for
humans; when the two disagree, fix both in the same pass.

## Known Items

| Item | Vault | Purpose | Typical consumer |
|------|-------|---------|------------------|
| `agent.heroku` | `agents-studio` | Heroku API key | `bin/ecosystem-build` |
| `github.mcritchie-agent` | `agents-studio` | GitHub App for the **build/review** lanes (the default identity): Contents + Pull requests + Checks read + Actions + Workflows across the McRitchie-Studio org. Fields: `app-id` = **`4431410`** (recorded here on purpose — see **GitHub App IDs** below), `client-id`; the private key is the **`.pem` FILE attachment** — the concealed `private key` field is NOT the key. | Two legs: `git push` via the global helper `bin/gh-app-git-credential`; `gh` PR create/merge + CI-status reads via a per-session minted `GH_TOKEN` (`bin/gh-app-mint-token`) — `gh` never consults git credential helpers (see `credentials.md` → GitHub). |
| `github.mcritchie-deployer` | `agents-admin` | GitHub App for the **ship** lane: Contents + Actions + Checks read + Secrets — **no pull-request scope by design** (the deployer cannot open or merge PRs). Fields: `app-id` = **`4431542`** (recorded here on purpose — see **GitHub App IDs** below), `client-id`; key is the **`.pem` FILE attachment**. | `production-deploy` / `bin/release ship` sessions, via `export GH_APP_ITEM=github.mcritchie-deployer` — in a shell that has run `source ~/.zprofile.admin` first, because only the admin token can read this vault. |
| `agent.github` | — (deleted) | **DELETED from 1Password** — verified absent from `agents-studio` on 2026-08-29, after both auth legs were proven on the App identities. It was the old `amcritchie` fine-grained PAT; fine-grained PATs cannot call the check-runs API, so the two GitHub Apps above replaced it. If a `gh` keyring still lists an `amcritchie` account, that is this PAT lingering: `gh auth logout -h github.com -u amcritchie`, then revoke it on GitHub. | Historical reference only. |
| `Agent API Secret` | `agents-studio` | Task-board API secret (`AGENT_API_SECRET`); auth for the agent task API. Also in app `.env` + Heroku config | McRitchie Studio task board (`POST /api/v1/auth`); see `task-board-api.md` |
| `agent.solana` | `agents-studio` | Legacy Alex Bot Solana wallet; retired after key rotation | Historical reference only |
| `agent.alex.solana` | `agents-studio` | Rotated Alex Bot/admin wallet | turf-vault and Turf Monster ops |
| `agent.mason.solana` | `agents-studio` | Mason wallet | multisig / agent wallet |
| `agent.mack.solana` | `agents-studio` | Mack wallet | agent wallet |
| `agent.turf.solana` | `agents-studio` | Turf Monster wallet | agent wallet |
| `agent.managed_wallet` | `agents-studio` | Managed wallet encryption key | Turf Monster managed-wallet flows |
| `agent.helius` | `agents-studio` | Devnet/mainnet Helius RPC URLs | Solana apps |
| `agent.aws.mcritchie-ses` | `agents-studio` | Shared SES-scoped AWS API credentials, region `us-east-2`; runtime SMTP credentials are derived/stored separately | McRitchie, Turf Monster, and future app email delivery |
| `agent.aws` | `agents-studio` | General AWS API credentials (S3 read/write, `us-east-2`); fields `access key` + `access secret key`. One IAM user, `mcritchie-s3`, backs **every** McRitchie app — read **Shared AWS identity** below before rotating or reusing it. Ignore the decoy `dont.use.agent.aws`. | Active Storage + reference-image (e.g. Pokémon) uploads, across hub, Turf Monster, Industries, and moms-app |
| `AWS` | `agents-admin` | IAM user `agents-admin` (account `534727954137`), created 2026-09-01. Fields `access-key` + `secret-access-key` (+ `account-id`, `region` = `us-east-2`). Policy `agents-admin-provisioning`: `s3:*`, mint/rotate IAM users under path `/mcr/*`, account read-only. It sits outside `/mcr/`, so it cannot edit its own policy; the admin service account's vault grant is READ-ONLY (`op item get` works, `op item edit` is refused — expected). | Steffon's `bucket-provision` sessions and fleet audits, via `source ~/.zprofile.admin` + the admin op token. Conventions: `modules/object-storage.md` |
| `Coinbase Developer Platform` | `agents-studio` | CDP API key | Turf Monster CDP ramp |
| `agent.higgesfield` | `agents-studio` | Higgsfield media generation API | McRitchie Studio content pipeline |
| `x.api` | `agents-studio` — **absent on 2026-08-29**; the X credentials present there are `agent.turf.x` | X/Twitter API credentials | McRitchie Studio news/content |

### Also present in `agents-studio` (listed 2026-08-29, not yet described)

Beyond the rows above: `agent.1password` (holds the
service-account token install recipe), `agent.rails_master_key`,
`agent.resend`, `agent.google`, `Google | McRitchie Studio`, `agent.gmail`,
`agent.rubygems`, `agents.cloudflare`, `agent.ipinfo.io`, `agent.coinflow`,
`agent.stripe`, `agent.stripe.sandbox`, `turf.stripe`, `Moonpay`,
`agent.turf.x`, `turf.squad`, `turf_vault-mainnet-keypair` (document),
`discord.webhooks`, `dont.use.agent.aws` (decoy — ignore). Describe an item
in the table above the first time a doc or script depends on it.

## GitHub App IDs — identifiers, not secrets

| App | 1Password item | Vault | `app-id` |
|-----|----------------|-------|----------|
| agent (build/review) | `github.mcritchie-agent` | `agents-studio` | **`4431410`** |
| deployer (ship) | `github.mcritchie-deployer` | `agents-admin` | **`4431542`** |

A convenience copy sits at `~/.config/mcritchie/app-ids.json` on Mr.
McRitchie's Mac. Nothing generates that file, so a rebuilt machine will not
have it — this table is the durable copy.

**Why they are written down.** `bin/gh-token` mints from two halves: the numeric
`app-id` and the `.pem` private key. Both used to live only in 1Password — so
when `op` was unreachable, the documented fallback ("mint from the `.pem` by
hand") needed the very service that was down. On 2026-08-30 that circle cost a
night: three finished tasks could not be pushed during a quota outage because
the agent `app-id` was not to hand. Recording the number breaks the circle. The
hand-mint recipe itself lives in `token-session.md`.

**Why this does not violate the "no secret values" rule at the top of this
file.** An app id is an *identity claim*, not a *proof of identity*. It is the
`iss` of the JWT, and GitHub verifies that JWT's signature against the app's
registered **public** key — so the id only chooses which key to check against.
Tested against the live API on 2026-08-30 rather than assumed:

| Test | Result |
|---|---|
| `GET /app` with an id and the `.pem` that matches it | `200` — the pairing is exact |
| the right `.pem`, the wrong id | `401` |
| the right id, the wrong `.pem` | `401` |
| the id and no key at all | `401 A JSON web token could not be decoded` |

The id is the username and the `.pem` is the password. Alone, it opens nothing.

**How public is "public" — precisely, because the loose version of this claim is
wrong.** Both Apps have profile pages that answer anonymously
(`https://github.com/apps/mcritchie-agent`, and the same for `-deployer`, both
`200`), but neither page prints the numeric id. `GET /apps/mcritchie-agent`
*does* return `{"id":4431410}` — to that App's **own** installation token, which
is a self-read; the same call for `mcritchie-deployer` from the agent's token is
`403`. So do not repeat "GitHub publishes these": what is demonstrated is that
the ids are **low-sensitivity internal identifiers**, not that a stranger can
fetch them.

That is still enough to write them down here, for three reasons. They confer
nothing without the `.pem` (the table above). They sit 132 apart in one
sequence, so withholding the second while the first is recorded buys nothing.
And on any machine where the `.pem` exists, the ids already sit beside it in
cleartext at `~/.config/mcritchie/app-ids.json` — the attacker this would
inconvenience is one who stole the key without the filesystem.

**Why the repo, rather than somewhere less public.** It is the only store that
survives BOTH a wiped Mac and a 1Password outage. That pair of failures is
exactly the case the number is needed for, and it is what `house-burn-down.md`
rebuilds from.

**What stays secret, and never enters this repo:** the `.pem` private key (the
FILE attachment on each item), the OAuth **client secret**, and any minted
installation token. `client-id` is likewise not a secret, but none is recorded
here, because nothing needs one.

## Shared AWS identity — `agent.aws`

One IAM user, `mcritchie-s3` (account `534727954137`, region `us-east-2`),
backs Active Storage for every McRitchie app. Sharing one identity across
brands is Mr. McRitchie's deliberate choice; this section records what that
choice costs, so the next reader learns it here rather than during an incident.

**Blast radius.** A leak of `agent.aws` exposes four brands at once — hub, Turf
Monster, Industries, and moms-app — with read **and write** on all seven
buckets below. Rotation is therefore an N-app coordinated change, not a single
`heroku config:set`: every consumer must move in one window, or the ones left
behind fail on their next upload.

| Bucket | Consumer | Objects world-readable |
|--------|----------|------------------------|
| `mcritchie-studio-production` | `mcritchie-studio` (live) | Yes |
| `mcritchie-studio-dev` | hub `amazon_dev` service | Yes |
| `turf-monster-production` | `turf-monster-mainnet` (live) | Yes |
| `turf-monster-dev` | Turf Monster dev | Yes |
| `mcritchie-industries-production` | `mcritchie-industries` **and** `mcritchie-industries-qa` — QA has no bucket of its own | **No** — flipped private 2026-09-01 while still empty |
| `mcritchie-industries-dev` | Industries dev | **No** — flipped private 2026-09-01 while still empty |
| `moms-app-production` | moms-app (deployed off the hub Heroku account) | **No** — the one private bucket |

**Where the value lives.** 1Password, plus each deployed consumer's
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` config vars. As of 2026-08-13 only
`mcritchie-studio` and `turf-monster-mainnet` carry them, and both are identical
to the 1Password item. Industries' `config/storage.yml` already names its bucket,
but neither `mcritchie-industries` nor `mcritchie-industries-qa` has the config
vars set — so Industries is wired but not yet authenticated, and joins the
rotation list the moment those vars land.

**Object posture** (probed live 2026-08-13):

- Every bucket is **`bucket-owner-enforced`**, so ACLs are **disabled**.
  `put_object(acl: "public-read")` raises `AccessControlListNotSupported`, and
  `public: true` in `storage.yml` makes every upload fail. Grant reads through
  the bucket policy, never a per-object ACL.
- Four of the seven — the studio and Turf Monster pairs — carry a standing
  **`PublicReadGetObject`** on `arn:.../*` with `block_public_policy=false`, so
  every object is world-readable. Three are exceptions, with no bucket policy and
  public access fully blocked: `moms-app-production`, which never had one, and
  both Industries buckets, flipped private 2026-09-01 (see the table above).
- **On those four, `public: false` is not a privacy control.** Active Storage
  hands out expiring presigned URLs and the expiry is genuine — the signed URL
  starts returning 403 on schedule. The bucket policy, though, keeps the raw
  object URL readable for as long as the object exists, so anyone holding the
  plain path keeps access long after the signature dies. Reasoning about privacy
  from `public: false` alone reaches the wrong conclusion; the only real fix is
  removing `PublicReadGetObject` from that bucket.
- Use **path-style** URLs (`https://s3.us-east-2.amazonaws.com/<bucket>/<key>`).
  Both styles serve the same object, but the virtual-hosted host
  (`<bucket>.s3.us-east-2.amazonaws.com`) resembles `mcritchie.studio` closely
  enough that Chrome's lookalike-domain protection shows a "this site looks fake"
  interstitial on direct navigation.

**Successor convention (2026-09-01).** Per-app IAM users under path `/mcr/`,
minted by Steffon's `bucket-provision` SOP, replace this shared identity for
every newly provisioned app; migrating an existing app off `mcritchie-s3` is
ladder work, one app per task, coordinated with that app's config vars. Rules
and tiers: `modules/object-storage.md`.

## Convention

Use `agent.<name>.<service>` for agent-owned identities, and clear product names for third-party integrations where a vendor UI uses that name.

Examples:

- `agent.steffon.aws`
- `agent.jasper.solana`
- `Coinbase Developer Platform`

When a credential is shared by every agent, prefer a product/integration item name over pretending one character owns it.
