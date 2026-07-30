# Credential Inventory

This file names credential locations so agents can ask for or reference the right item without searching vaults. It must never contain secret values.

## Vaults

| Vault | Purpose |
|-------|---------|
| `agents` | Default agent-readable vault. Service account should have read access. |
| `Blockchain` / `🧱 Blockchain` | Human-controlled blockchain credentials, if granted. |

## Known Items

| Item | Vault | Purpose | Typical consumer |
|------|-------|---------|------------------|
| `agent.heroku` | `agents` | Heroku API key | `bin/ecosystem-build` |
| `github.mcritchie-agent` | `agents` | GitHub App for the **build/review** lanes (the default identity): Contents + Pull requests + Checks read + Actions + Workflows across the McRitchie-Studio org. Fields: `app-id`, `client-id`; the private key is the **`.pem` FILE attachment** — the concealed `private key` field is NOT the key. | `git push`, `gh` PR create/merge, CI-status reads — all agents, via `bin/gh-app-git-credential` (see `credentials.md` → GitHub). |
| `github.mcritchie-deployer` | `agents` | GitHub App for the **ship** lane: Contents + Actions + Checks read + Secrets — **no pull-request scope by design** (the deployer cannot open or merge PRs). Fields: `app-id`, `client-id`; key is the **`.pem` FILE attachment**. | `production-deploy` / `bin/release ship` sessions, via `export GH_APP_ITEM=github.mcritchie-deployer`. |
| `agent.github` | `agents` | **DEPRECATED pending deletion** (2026-07-29 org migration). The old `amcritchie` fine-grained PAT — fine-grained PATs cannot call the check-runs API, so it was replaced by the two GitHub Apps above. Do not wire it into anything new. | Historical reference only. |
| `Agent API Secret` | `agents` | Task-board API secret (`AGENT_API_SECRET`); auth for the agent task API. Also in app `.env` + Heroku config | McRitchie Studio task board (`POST /api/v1/auth`); see `task-board-api.md` |
| `agent.solana` | `agents` | Legacy Alex Bot Solana wallet; retired after key rotation | Historical reference only |
| `agent.alex.solana` | `agents` | Rotated Alex Bot/admin wallet | turf-vault and Turf Monster ops |
| `agent.mason.solana` | `agents` | Mason wallet | multisig / agent wallet |
| `agent.mack.solana` | `agents` | Mack wallet | agent wallet |
| `agent.turf.solana` | `agents` | Turf Monster wallet | agent wallet |
| `agent.managed_wallet` | `agents` | Managed wallet encryption key | Turf Monster managed-wallet flows |
| `agent.helius` | `agents` | Devnet/mainnet Helius RPC URLs | Solana apps |
| `agent.aws.mcritchie-ses` | `agents` | Shared SES-scoped AWS API credentials, region `us-east-2`; runtime SMTP credentials are derived/stored separately | McRitchie, Turf Monster, and future app email delivery |
| `agent.aws` | `agents` | General AWS API credentials (S3 read/write, `us-east-2`); fields `access key` + `access secret key`. Bucket `mcritchie-studio-production` is bucket-owner-enforced (no ACLs) with a standing public-read policy on `/*` — use **path-style** URLs (`s3.us-east-2.amazonaws.com/<bucket>/…`) to avoid Chrome's lookalike warning. Ignore the decoy `dont.use.agent.aws`. | Active Storage + reference-image (e.g. Pokémon) uploads |
| `Coinbase Developer Platform` | `agents` | CDP API key | Turf Monster CDP ramp |
| `agent.higgesfield` | `agents` | Higgsfield media generation API | McRitchie Studio content pipeline |
| `x.api` | `agents` | X/Twitter API credentials | McRitchie Studio news/content |

## Convention

Use `agent.<name>.<service>` for agent-owned identities, and clear product names for third-party integrations where a vendor UI uses that name.

Examples:

- `agent.steffon.aws`
- `agent.jasper.solana`
- `Coinbase Developer Platform`

When a credential is shared by every agent, prefer a product/integration item name over pretending one character owns it.
