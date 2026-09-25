# Credentials

> **Restoring credentials on a fresh Mac?** `bin/ecosystem-build` does this automatically: it pulls `RAILS_MASTER_KEY` and other env vars from `heroku config` and `SOLANA_ADMIN_KEY` from 1Password (`solana.turf.admin`, in `studio-agents` — the ordinary agent token reads it; no admin token needed since 2026-09-15), then writes `.env` for both Rails apps. See [house-burn-down.md](house-burn-down.md). This doc is legacy system context while the neutral modules in `docs/agents/modules/` become canonical.

## Environment Variables

All sensitive credentials are stored as environment variables, never in code.

### Required
- `DATABASE_URL` — PostgreSQL connection string (production only)

### Optional
- `GOOGLE_CLIENT_ID` — Google OAuth client ID
- `GOOGLE_CLIENT_SECRET` — Google OAuth client secret
- `RAILS_MASTER_KEY` — Rails encrypted credentials key
- `SOLANA_ADMIN_KEY` — Turf Monster's onchain signing key (base58). **Two different keys wear this name**: on the Heroku dynos it is Xan (`8K81…`, `agent.xan.solana`); in a local `.env` written by `bin/ecosystem-build` it is `solana.turf.admin` (`BLSBw8fX…`). See **Onchain Admin** below
- `ANTHROPIC_API_KEY` — Claude API key for AI chat (McRitchie Studio)
- `X_BEARER_TOKEN` — X (Twitter) API bearer token for News intake (McRitchie Studio). See `docs/agents/system/news-pipeline.md` for setup.

## Development Defaults

- Database: `mcritchie_studio_development` (local PostgreSQL, no password)
- Admin login: `alex@mcritchie.studio`; sign in by magic link in normal local development.
- API: No authentication required (add token auth later)

## Agent Email Accounts

All agents share a primary Gmail account and have individual forwarding addresses on the `mcritchie.studio` domain.

### Shared Account
- **Email**: `team@mcritchie.studio` — shared Gmail account used by all agents
- **1Password**: Credentials stored in the `alex@mcritchie.studio` 1Password account

### Per-Agent Forwarding Addresses
Each agent has a dedicated email that forwards to the shared `team@mcritchie.studio`
inbox — **except Turf Monster**, which is a real Google user on its own domain (see the
note under the table):

| Agent | Email | Purpose |
|-------|-------|---------|
| Xan | `admin@mcritchie.studio` | Orchestrator, admin notifications |
| Avi | `avi@mcritchie.studio` | Product Owner — PR review, release sign-off, ticket grooming |
| Carl | `carl@mcritchie.studio` | Dev Backend Expert — Rails, ActiveRecord, jobs |
| Shannon | `shannon@mcritchie.studio` | Dev UI Expert — frontend, Tailwind, Alpine, theme |
| Jasper | `jasper@mcritchie.studio` | Dev Blockchain Expert — turf-vault, solana-studio, Phantom |
| Steffon | `steffon@mcritchie.studio` | Infrastructure Expert — Heroku, deploys, CI, OPSEC |
| Turf Monster | `team@turfmonster.media` | Sports data, Turf Monster app notifications — **own domain, not a forwarder** |
| Mack | `mack@mcritchie.studio` | Worker agent comms — scraping, processing, bulk ops |
| Mason | `mason@mcritchie.studio` | Marketing — brand voice, launch comms, social, funnels (was Infrastructure pre 2026-05-23 — see `mission.md`) |

> The 5 new agents (Avi/Carl/Shannon/Jasper/Steffon) were added 2026-05-23 alongside Mason's
> pivot from Infrastructure to Marketing; persona definitions live at `docs/agents/agents/<slug>/`.
> The forwarding addresses now EXIST as Google Groups on `mcritchie.studio`, each redirecting
> into the shared `team@mcritchie.studio` inbox — so every soul reads the same mailbox and the
> per-agent address is an addressing convention, not a separate account to sign in to.
>
> **Turf Monster is the exception, as of 2026-09-04.** `turf@mcritchie.studio` was a group with
> zero members and is being deleted; the soul now uses `team@turfmonster.media`, a real Google
> user on Turf's own domain (1Password `google.turf.agents`). It is the one agent address that is
> NOT a redirect into the studio inbox.
>
> These addresses are also seeded as app accounts — `User::PARKED_IDENTITIES` in
> mcritchie-studio and turf-monster is the source of truth for which of them hold `admin`.
> `admin@mcritchie.studio` is the super-admin seat shared by Xan and Steffon, and carries no
> Solana wallet on purpose.
>
> **Editing that list does not change an account that already exists.** The roster is read
> on SAVE (`assign_parked_identity`), and a release saves nothing — so a demotion waits for
> its owner to sign in, which for a shared house account may be never. Measured: mack@ stayed
> an admin in production for twenty-one days after the roster made him a viewer. A role or
> name change to a deployed seat rides a data migration (see
> `db/migrate/20260904190000_rename_turf_house_identity.rb`); the seed carries it for local,
> test, and QA.

## Solana Wallets

Each agent has a dedicated Solana wallet. Credentials stored in 1Password. The three vault-admin identities below (Xan, Mr. McRitchie's Phantom, Mason) are **the same keys on devnet and mainnet** — verified 2026-09-05 as the `VaultState.signers` set on both clusters — so a rotation of any of them is a mainnet event, not a devnet one. The other rows were not part of that verification: check the cluster before assuming any of them is devnet-only.

### Wallet Addresses

| Agent | Address | Role |
|-------|---------|------|
| Xan | `8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd` | Rotated vault admin (signs routine onchain ops) |
| Mr. McRitchie's Phantom | `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr` | Backup vault admin (recovery only) |
| Mason | `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR` | Vault signer (third 2-of-3 cosigner) |
| Mack | `foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds` | Agent wallet |
| Turf Monster admin | `BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo` | Agent governance identity (`solana.turf.admin`) |
| Turf Monster system | `7auwTLSvNniSUeAgL6v9RStMXJhWrrUhSJgwFWLpcqC` | Server operational key, MAINNET (`solana.turf.system`) — **read the balance, do not quote one.** 0 SOL at 09:12 on 2026-09-15, funded at 09:20 that morning; `1000000000` lamports (1.0000 SOL) at `finalized` later the same day. The cutover judges whether that is sufficient for **sustained fee payment**, not merely non-zero |
| Turf Monster system (devnet) | `2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9` | Server operational key, devnet/QA (`solana.turf.system.devnet`) |

### 1Password CLI Access

Wallet credentials are stored in the `alex@mcritchie.studio` 1Password account. Use the CLI to retrieve them programmatically.

There are **two access modes** — agent sessions use the service account, humans use the desktop-app integration:

#### Agent sessions: service-account access (canonical pattern — read this first)

Claude/agent sessions are already authenticated: a 1Password **service account** token lives in `~/.zprofile` (`OP_SERVICE_ACCOUNT_TOKEN`, installed by `mcritchie-studio/bin/setup-1pass-token`), and agent shells initialize from the profile. Verify with `/opt/homebrew/bin/op whoami` (expect `User Type: SERVICE_ACCOUNT`). No `--account` flag, no biometric prompt, no token-sourcing preamble needed.

- **Scope**: the service account sees only the **agents** vault. Anything agents need must be stored there (`agent.*` naming convention, or product items like `Coinbase Developer Platform`).
- **Always invoke by full path** — `/opt/homebrew/bin/op read|item|vault …`. The session permission allow-rules match these full-path prefixes. Prefixing commands with `eval`/`export` token-sourcing, or running broad vault scans/listing hunts, trips the permission classifier as "credential exploration" and gets blocked.
- **Never print secrets.** Pull secret fields clipboard-only and consume from there; print only non-secret fields (key IDs, addresses, usernames). Avoid `op item get --format json` on items with secret fields — it dumps the secret into the session transcript.

Worked example (CDP key → turf-monster `.env`):
```bash
cd ~/projects/turf-monster && bin/setup-cdp-key   # no args → reads the key from 1Password (op://<agent-vault>/Coinbase Developer Platform) → writes .env, never echoes the secret
```
`bin/setup-cdp-key` defaults to a 1Password pull (PR #144); `--clipboard` (full JSON blob) and `bin/setup-cdp-key <key-id>` (secret in clipboard) remain as first-time/fallback modes.

- **Hard boundaries — don't fight them**: agent sessions cannot scan vaults for credentials they weren't pointed at, and cannot edit `.claude/settings*.json` to self-grant access. Targeted reads of operator-named items via the allowed full-path commands are the sanctioned path. (Codified 2026-06-09 after the CDP key retrieval hit both walls.)

#### Human/desktop access

**Prerequisites**: Install `brew install 1password-cli`, then enable "Integrate with 1Password CLI" in 1Password desktop app (Settings > Developer).

**Account ID**: `MWOV5OT5BRHATI4EGMN26C5DPA`

**Vault layout**:
- `studio-agents` — All agent wallet credentials (renamed from "🦞 Bots" 2026-05-03, and from `agents` 2026-08-28)
- `🧱 Blockchain` — General blockchain credentials

**Retrieve a wallet's private key** (items renamed 2026-05-03 to `agent.*` convention):
```bash
# Xan (needs the ADMIN token — source ~/.zprofile.admin)
op item get "agent.xan.solana" --vault "studio-agents-admin" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private key"

# Mason
op item get "agent.mason.solana" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private key"

# Mack
op item get "agent.mack.solana" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private key"

# Turf Monster — the three solana.turf.* items spell their labels with HYPHENS
# (`private-key`, `wallet-address`), unlike every agent.* item above. `op` fails
# the whole read on one wrong label rather than falling back, so the spelling is
# not transferable between these two groups.
op item get "solana.turf.admin" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private-key"
op item get "solana.turf.system" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private-key"
op item get "solana.turf.system.devnet" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private-key"
```

> **`agent.turf.solana` is gone as an address.** Two items still carry that exact
> title and `op` refuses with "More than one item matches"; both are superseded
> and awaiting a deletion only Mr. McRitchie can perform (the agent service
> account is read-only). Use the three titles above.

**Set as env var (one-liner)**:
```bash
export SOLANA_ADMIN_KEY=$(op item get "solana.turf.admin" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private-key")  # agent token; local/dev value
```

**Item fields**: this is NOT uniform, and assuming it is breaks the read — `op` fails the whole call on one wrong label rather than falling back. The older `agent.*` wallets carry `recovery phrase`, `private key` and `wallet address`, SPACED. The three `solana.turf.*` items above carry `private-key` and `wallet-address`, HYPHENATED, plus `phantom-email` / `phantom-password`, and no recovery phrase (verified 2026-09-15). `phantom.turf` mixes the two spellings on one item. When in doubt read `--format json` and pick whichever spelling is present, which is what `KeyStore#op_read_item` does.

### Onchain Admin

**TWO AUTHORITIES, AND SINCE 2026-09-15 THEY DISAGREE.** Both re-measured on-chain at `finalized` on 2026-09-15, through two independent RPC providers:

| Authority | What it controls | Live set |
|---|---|---|
| Squads V4 multisig — **one per cluster, and they differ** | the program **upgrade** authority | **threshold 3 of FIVE**, all mask 7. mainnet `4H3fP3ot…`: `7auwTL…`, `3Qj4v9…`, `7ZDJ…`, `9gACbz…`, `BLSBw8…`. devnet `7nRuVw3V…`: `2eGs8G3w…`, `3Qj4v9…`, `7ZDJ…`, `8K81…`, `BLSBw8…` |
| `VaultState.signers` (`seeds = [b"vault"]`, deployed v0.25.0) | treasury + governance ops — *the money* | **2-of-3** — `8K81…`, `7ZDJ…`, `CytJ…`, unchanged on both clusters |

**They are two different authorities with different thresholds — but on mainnet their MEMBERSHIP has converged, and not by design.** Both are five wallets; Squads is live at threshold 3, `VaultState` is the target at threshold 2 once `update_signers` runs:

| Wallet | Squads mainnet (upgrade) | `VaultState.signers` (the money) |
|---|---|---|
| system `7auwTL…` (`solana.turf.system`) | ✅ **seated, mask 7 — against policy** | slot 1 |
| admin `BLSBw8…` (`solana.turf.admin`) | ✅ | slot 2 |
| Mr. McRitchie's Phantom `7ZDJ…` | ✅ | slot 3 |
| Mr. McRitchie's second `3Qj4v9…` | ✅ | slot 4 |
| Mr. McRitchie's third `9gACbz…` | ✅ | slot 5 |

⚠ **THE SYSTEM KEY WAS MEANT TO BE OFF SQUADS. ON CHAIN IT IS NOT.** The policy is right and unchanged: `7auwTL…` is the app's HOT operational key — it lives in Heroku config on a running web dyno and signs on every entry and every payout. That makes it the most exposed key in the system and the last one that should hold program upgrade authority, and it has no job there anyway, since upgrading a program is a rare, deliberate, human act and never something the server does unattended. **What the chain says is the opposite:** `7auwTL…` holds `Initiate|Vote|Execute` on the mainnet Squad, and `2eGs8G3w…` (`solana.turf.system.devnet`) holds the same on devnet. This document asserted the policy as fact for a day. Closing the gap is a **Squads config transaction** with Mr. McRitchie's signature on it — its own task, not an edit here. **Bound the exposure correctly, though, because overstating it is its own kind of wrong:** that dyno holds ONE seat of five against a threshold of THREE, so compromising it alone does **not** reach program upgrade authority — it buys an attacker the ability to open a proposal and cast one of the three approvals it needs. The real shape is subtler and is the reason this still matters: it is a seat the agent can reach without Mr. McRitchie, which alongside `BLSBw8…` makes **two of the three**. The third must still come from one of his personal wallets. So the margin is one signature where the policy intended two.

So the agent holds **2 of 5 on mainnet Squads** (`BLSBw8…`, plus the agent-readable `7auwTL…`) against a threshold of 3 — one short, so a mainnet upgrade still needs Mr. McRitchie. On devnet the agent reaches **3 of 5** (`BLSBw8…`, `8K81…`, `2eGs8G3w…`) and can act alone. Once `update_signers` runs the agent holds **2 of 5 on the vault** as well. Five seats against a threshold of three keeps an attacker two signatures short.

**The five-member vault set is blocked on a PROGRAM UPGRADE, not on a ceremony.** Deployed v0.25.0 declares `update_signers(new_signers: [Pubkey; 3])` against `signers: [Pubkey; 3]` — it can only ever write three, and it replaces the whole set. turf-vault's `accepted` does NOT widen that array: it keeps `signers: [Pubkey; 3]` at offset 0 and **APPENDS `signers_ext: [Pubkey; 2]` at offset 1443**, reading the whole set through **`all_signers()`** — five slots, appended rather than widened so the upgrade stays layout-compatible on a `zero_copy` singleton. So slots 4 and 5 are never in `VaultState.signers`; a reader that only looks there sees three and is not wrong, it is looking at the wrong field. "Three" and "five" are each true of a different build, and that gap is the design, not a discrepancy — check what the cluster runs before trusting any count. The order is therefore forced:

1. **Restore a working upgrade path — DONE 2026-09-15** (turf-vault `280cebf`, on `accepted`, `release` and `main`). `scripts/squad-upgrade.js` now requires `--cluster=devnet|mainnet`, dry-runs unless `--send` arms it, reads the live Squads membership on every run, and signs only with the seats in `scripts/lib/squad-clusters.js` `AGENT_SEATS` that the chain still seats. On devnet its three seats (`2eGs8G3w…`, `BLSBw8…`, `8K81…`) reach threshold 3, so it runs end to end. On mainnet its two seats (`7auwTL…`, `BLSBw8…`) cast their approvals and it stops for Mr. McRitchie. It no longer loads `ALEX_BOT_KEY` or `MASON_KEY`; `scripts/tests/squad-upgrade-signers.test.js` pins that.
2. **Deploy v0.26**, which is what puts `signers_ext` on-chain.
3. **Re-pin `EXPECTED_IDL_HASH`** on `turf-monster-mainnet` from the BUILT IDL; the v0.26 change alters the IDL.
4. **Only then `update_signers`** with the five-member set.

Attempting step 4 first does not fail harmlessly — it spends a ceremony and Mr. McRitchie's signatures on a transaction the live program cannot accept.

⚠ **Never write "the multisig" unqualified.** Say *Squads* or *`VaultState`* every time. The unqualified form is exactly what produced the stale claims this section replaces, twice in one day.

**It was TWO ceremonies, five minutes apart — not one transaction across both clusters.** Signature history: devnet executed **09:41:25 MDT** (its Squad's transaction #16), mainnet **09:46:51-55 MDT** (transaction #3), on 2026-09-15. The two carried the same membership change. The clusters diverged that AFTERNOON, in later transactions: mainnet #4 added `7auwTL…` at 13:27:29 MDT, and devnet #18 added `2eGs8G3w…`, re-added `8K81…` and removed `9gACbz…` at 14:02:10 MDT. Each cluster's Squad keeps its own transaction history, so say which cluster you mean. **Devnet proposal #17 is dead and needs no action.** It was open when #18 executed, and executing a config transaction stales every earlier index. Squads then refuses every move on it: reject fails `StaleProposal` (6007) and cancel fails `InvalidProposalStatus` (6008, because cancel needs an Approved proposal). So #17 stays `Active` with one approval (`BLSBw8…`) and can never execute (keyless simulations, 2026-09-16). A stale proposal that never reached Approved cannot be cancelled either; it is simply inert. One that had reached Approved still cancels, and a stale Approved vault transaction still executes (`credential-rotation.md`, "One transaction, not two").

Both ceremonies removed Mason (`CytJ…`) and Xan (`8K81…`). Mason is still absent from each account. **Xan is not: devnet transaction #18 put `8K81…` back** (slot `498932200`), so today it is seated on devnet and absent on mainnet. Read at `finalized` 2026-09-16, from each Squad's config transactions. This paragraph has stated each half as the whole: "removed from both" (committed 10:32 MDT, true until 14:02) and then "removed from mainnet only" (committed that evening, reading the devnet re-seat as if the removal had never happened). Neither ceremony, nor #18, touched any `VaultState`. The upgrade tooling no longer depends on either seat: the rebuilt `squad-upgrade.js` reads membership off the chain, so it offers `8K81…` on devnet and never on mainnet (step 1 above). Xan remains a live `VaultState` cosigner throughout. A change to one authority is never a change to the other; read the one you mean, on the cluster you mean.

**The first mainnet deployment is retired (2026-09-16).** The leaked `F6f8…` had kept a seat on it: program `mnzow…` under Squad `9dCLM…` (Squads 2-of-3: `7ZDJ…`, `CytJ…`, `F6f8…`). Mr. McRitchie signed both steps. Vault transaction #1 CLOSED `mnzow…` and swept its ~3.50 SOL of rent to `Bk9sS7ii…`, the live mainnet Squad's vault (executed 8:27 PM MDT, `02:27:09Z` on the 17th). Config transaction #2 removed `F6f8…` and `CytJ…` and set the threshold to 1, leaving `7ZDJ…` alone on `9dCLM…` (executed 8:38 PM MDT). Squads cannot close a multisig account, so `9dCLM…` persists with a little rent and controls nothing. The dead program's `VaultState` still holds `F6f8…`'s bytes, but a closed program cannot act on them. Neither transaction changed the live Squad `4H3fP3ot…` or the live program `DaFv83yo…`; the live vault only received the rent. Every signature and the post-flight chain reads are recorded on the board task `retire-leaked-key-mainnet-deployment`.

⚠ `3Qj4v9…`, `7ZDJ…` and `9gACbz…` are Mr. McRitchie's **personal** wallets. Their Squads seats differ by cluster: `3Qj4v9…` and `7ZDJ…` sit on both, and `9gACbz…` sits on mainnet only, because devnet transaction #18 removed it (read at `finalized` 2026-09-16). All three are deliberately filed in **no vault at all** — never file one into an agent-readable vault to unblock a ceremony. **Read the arithmetic before deciding how strict that rule is:** the agent already holds `BLSBw8…` by name and reaches `7auwTL…` through the same `studio-agents` vault, which is **two of the three** approvals a mainnet Squads transaction needs. So filing **one** of his wallets hands the agent the threshold outright — not three filings, one. The unblock is always his signature, never a filing.

Deployment identity for both clusters lives in `turf-vault/docs/CURRENT_DEPLOYMENT.md`: each of its `## Devnet` and `## Mainnet` tables carries that cluster's program ID, Squads upgrade authority, threshold and three signer rows. **Read the heading you mean** — the two `VaultState` signer sets agree on both clusters today, but nothing in the program ties them together, so an address alone cannot tell you which cluster you are on. `turf-vault/scripts/squad.json` (`members`) is provenance and a script input — `scripts/initialize-mainnet.js` builds its `initialize` signer array from it — not the deployment record. Confirm the live set on-chain from `VaultState` (`seeds = [b"vault"]` against that cluster's program ID) rather than from any file. The `SOLANA_ADMIN_KEY` env var in Turf Monster's **local** `.env` holds `solana.turf.admin` (`BLSBw8fX…`, vault `studio-agents`, hyphenated labels) — that is what `bin/ecosystem-build` writes. **Production still holds a different key**: `turf-monster-mainnet`'s `SOLANA_ADMIN_KEY` is Xan (`8K81…`, `agent.xan.solana`, vault `studio-agents-admin`), and the move onto `solana.turf.system` is a separate task gated on funding that wallet. Local and deployed differ on purpose.

## AWS — S3 + Amazon SES

Credential names and provider status now live in the modular docs:

- Shared credential inventory: [`../modules/credential-inventory.md`](../modules/credential-inventory.md)
- Shared email operations: [`../modules/email-operations.md`](../modules/email-operations.md)
- McRitchie-specific delivery notes: `docs/email-delivery.md` (outside the docs viewer's root, so not a link)

Do not duplicate SES production status here; it changes as AWS support,
DNS verification, and runtime SMTP credentials move.

## Security Notes

- Never commit `.env` files or credential files
- API is currently open (no auth) — suitable for local/trusted networks only
- Google OAuth credentials must be configured per environment
- Password hashing uses bcrypt via `has_secure_password`
- 1Password CLI: human/desktop mode requires biometric or password auth on each use; agent sessions use scoped service-account tokens — the agent lane sees the agent vault, the ship lane's separate token sees the admin vault (see `bin/lib/op_vaults.rb`) — credentials are never cached in plaintext either way
- Private keys should only be stored in 1Password and `.env` files (gitignored), never in code or commits
