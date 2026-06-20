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
| `agent.github` | `agents` | GitHub fine-grained PAT for `git`/`gh` **write** auth — Contents / Pull requests / Workflows read+write, Actions / Commit statuses read, across the ecosystem repos. Field: `personal-access-token-read-write-2026`. Rotate before its GitHub expiry. | `git push`, `gh` PR create/merge, CI-status reads — all agents. Wire with `gh auth login --with-token` (see `credentials.md` → GitHub). |
| `Agent API Secret` | `agents` | Task-board API secret (`AGENT_API_SECRET`); auth for the agent task API. Also in app `.env` + Heroku config | McRitchie Studio task board (`POST /api/v1/auth`); see `task-board-api.md` |
| `agent.solana` | `agents` | Legacy Alex Bot Solana wallet; retired after key rotation | Historical reference only |
| `agent.alex.solana` | `agents` | Rotated Alex Bot/admin wallet | turf-vault and Turf Monster ops |
| `agent.mason.solana` | `agents` | Mason wallet | multisig / agent wallet |
| `agent.mack.solana` | `agents` | Mack wallet | agent wallet |
| `agent.turf.solana` | `agents` | Turf Monster wallet | agent wallet |
| `agent.managed_wallet` | `agents` | Managed wallet encryption key | Turf Monster managed-wallet flows |
| `agent.helius` | `agents` | Devnet/mainnet Helius RPC URLs | Solana apps |
| `agent.aws.mcritchie-ses` | `agents` | Shared SES-scoped AWS API credentials, region `us-east-2`; runtime SMTP credentials are derived/stored separately | McRitchie, Turf Monster, and future app email delivery |
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
