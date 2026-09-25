# Credential Inventory

This file names credential locations so agents can ask for or reference the right item without searching vaults. It must never contain secret values.

## Vaults

| Vault | Purpose |
|-------|---------|
| `studio-agents` | The **agent** vault — every build, review, and QA lane reads it through `OP_SERVICE_ACCOUNT_TOKEN`. Holds `slack.studio.agents` (read-only Slack token, consumed by `Slack::Credentials` in mcritchie-industries). It is the vault formerly named `agents` (renamed 2026-08-28; same vault id `txqp6ijdo3ujsfhsfzdj5h5dzq`). |
| `studio-agents-admin` | The **admin** vault — `github.mcritchie-deployer` and other ship-lane credentials. Read only by a SEPARATE service account (`OP_ADMIN_SERVICE_ACCOUNT_TOKEN`, sourced from `~/.zprofile.admin`); the agent token is never granted it, so an ordinary agent shell cannot even list it. That invisibility is the design, not a fault. |
| `industries-agents` | Industries-brand agent credentials. Created 2026-08-28. **Visible to the agent service account** — re-measured 2026-09-16, `op vault list` returns it. The 2026-08-29 reading that it was invisible is superseded; a grant landed in between and this census did not catch up. |
| `family-agents` | Family-brand agent credentials. Created 2026-08-28. **Visible to the agent service account** — re-measured 2026-09-16. The 2026-08-29 reading that it was invisible is superseded; a grant landed in between and this census did not catch up. |
| `Commercial Welding` | Reserved for the Commercial Welding initiative. Created 2026-08-28. **Visible to the agent service account** — re-measured 2026-09-16. The 2026-08-29 reading that it was invisible is superseded. |
| `studio-applications` | **Deterministic application/CI credentials** — consumed by deployed software, never by agent judgment: the durable copies of Heroku config vars and GitHub Actions secrets. Created 2026-09-02. Admin service account WRITES here (the provisioning lane files fleet credentials — this is the one vault where agent-side write is by design); agent service account reads. Grants pending as of 2026-09-02. |
| `Blockchain` / `🧱 Blockchain` | Human-controlled blockchain credentials, if granted. |

**Vault naming is entity-first** (`<entity>-<consumer>`), renamed 2026-09-02 from
the older `agents-<entity>` shape — same vault ids, so ID-pinned tooling never
noticed. The rule that picks a vault is the CONSUMER: a credential wielded by a
session's judgment lives in an `-agents` vault (tiered `-agents-admin` for
provisioning/ship lanes); one consumed deterministically by software lives in
`-applications`. The rotation runbook follows the vault: application credentials
rotate by redeploying config, agent credentials by re-minting lanes.

`bin/lib/op_vaults.rb` is the one place code names a vault (`MCR_OP_VAULT_AGENT` /
`MCR_OP_VAULT_ADMIN` override it per machine). The names in this table are for
humans; when the two disagree, fix both in the same pass.

## Known Items

**WHERE DEADNESS IS RECORDED — a convention, because a guard reads it.**
`test/lib/env_example_credential_pointers_test.rb` fails the build when
`.env.example` points at an item this table marks dead, and it reads that mark
from the **name cell** or the **vault cell** only — never from the purpose prose,
because the live `higgsfield.studio.agents` row says "Supersedes
`agent.higgesfield`" and a row-wide match would condemn the replacement along
with the thing it replaced. Three spellings are in use, and all three are live in
the table below: `RETIRED` in the name (`agent.higgesfield (RETIRED - use …)`),
`DELETED` / `(deleted)` in the vault cell (`agent.github`), and **absent** in the
vault cell (`x.api`). **So retire an item in its NAME or its VAULT cell.** A
marker written only into the purpose sentence is invisible to that guard, and the
guard passes — the silent-green failure the whole tripwire exists to stop. The
same guard also requires every `.env.example` pointer to HAVE a row here,
including a row that records an item is not filed at all.

| Item | Vault | Purpose | Typical consumer |
|------|-------|---------|------------------|
| `heroku.studio.agents` | `studio-agents` | Heroku **agent lane** OAuth authorization (`dec169b0…`), scope `identity,read-protected,write-protected` — deploys, config vars, one-off dynos, logs, app creates; CANNOT transfer apps or manage authorization lanes (and could technically delete an app — SOP forbids). Item notes carry this permission matrix — the Heroku items follow `heroku.studio.<lane>` with the lane named after its vault. Staged as `HEROKU_STUDIO_AGENTS_API_KEY` in `~/.zprofile.admin`; at the account cutover it becomes `HEROKU_API_KEY` in `~/.zprofile`. Replaced `agent.heroku` (global-scope lane `b6697b95…`, revoked 2026-09-02). | `bin/ecosystem-build`, agent sessions (`heroku run`, ship git-pushes), Avi QA deploys, Steffon prod deploys |
| `Heroku` | `studio-agents-admin` | The MASTER account login for alex@mcritchie.studio: password, TOTP, recovery codes. The dashboard's master API key is deliberately NOT stored anywhere — break-glass = reveal it in the dashboard behind MFA. | Operator only |
| `heroku.studio.admin` | `studio-agents-admin` | Filed 2026-09-02 by the admin lane (the vault became admin-lane-writable that day — a new admin service account with read+write; before that, agent writes were refused by design). Heroku **admin lane** OAuth authorization (`66cd4db9…`), scope `global` — the only lane that can transfer apps, grant access, and manage the authorization lanes; "never delete an app" is SOP, not scope (Heroku cannot separate delete from write). Staged as `HEROKU_STUDIO_ADMIN_API_KEY` in `~/.zprofile.admin`. | Steffon provisioning acts, via the admin profile |
| `heroku.studio.applications` | `studio-applications` | Heroku **CI lane** OAuth authorization (`d976c7b8…`), scope `identity,read-protected,write-protected` (same matrix as the agents lane; in the item notes). Runtime home is the Actions `HEROKU_API_KEY` secret at cutover; staged as `HEROKU_STUDIO_APPLICATIONS_API_KEY` in `~/.zprofile.admin`. Replaced `mcritchie-studio.github-actions-heroku` (global-scope lane `1f468f88…`, revoked 2026-09-02). | GitHub Actions deploys |
| `mcritchie-industries.aws` | `studio-applications` | Filed 2026-09-02. The AWS pair the mcritchie-industries Heroku app runs with (S3 knowledge-layer buckets; IAM under `/mcr/`); mirrors the app's `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` config vars — rotate both together. | Industries app + QA |
| `github.mcritchie-agent` | `studio-agents` | GitHub App for the **build/review** lanes (the default identity): Contents + Pull requests + Checks read + Actions + Workflows across the McRitchie-Studio org. Fields: `app-id` = **`4431410`** (recorded here on purpose — see **GitHub App IDs** below), `client-id`; the private key is the **`.pem` FILE attachment** — the concealed `private key` field is NOT the key. | Two legs: `git push` via the global helper `bin/gh-app-git-credential`; `gh` PR create/merge + CI-status reads via a per-session minted `GH_TOKEN` (`bin/gh-app-mint-token`) — `gh` never consults git credential helpers (see `credentials.md` → GitHub). |
| `github.mcritchie-deployer` | `studio-agents-admin` | GitHub App for the **ship** lane: Contents + Actions + Checks read + Secrets — **no pull-request scope by design** (the deployer cannot open or merge PRs). Fields: `app-id` = **`4431542`** (recorded here on purpose — see **GitHub App IDs** below), `client-id`; key is the **`.pem` FILE attachment**. | `production-deploy` / `bin/release ship` sessions, via `export GH_APP_ITEM=github.mcritchie-deployer` — in a shell that has run `source ~/.zprofile.admin` first, because only the admin token can read this vault. |
| `agent.github` | — (deleted) | **DELETED from 1Password** — verified absent from `studio-agents` on 2026-08-29, after both auth legs were proven on the App identities. It was the old `amcritchie` fine-grained PAT; fine-grained PATs cannot call the check-runs API, so the two GitHub Apps above replaced it. If a `gh` keyring still lists an `amcritchie` account, that is this PAT lingering: `gh auth logout -h github.com -u amcritchie`, then revoke it on GitHub. | Historical reference only. |
| `Agent API Secret` | `studio-agents` | Task-board API secret (`AGENT_API_SECRET`); auth for the agent task API. Also in app `.env` + Heroku config | McRitchie Studio task board (`POST /api/v1/auth`); see `task-board-api.md` |
| `google.industries.agents` | `industries-agents` | **FILED EMPTY** on 2026-09-18 by the admin lane (item id `osw6lmzh2lxzrhkvxl6l35t57m`) under the `<service>.<entity>.<lane>` convention; Alex pastes the value. An earlier draft of this row and of the code named it `google.drive.agents`, which does not follow the convention — do not file that name. Field `credential` = a Google service-account JSON key, used under domain-wide delegation with exactly four scopes: `drive.readonly`, `drive.file`, `gmail.readonly`, `gmail.compose`. Grant all four on the Workspace admin console's delegation page for the key's client id. `gmail.compose` CAN send mail, so "never sends" is enforced in code (`test/lib/no_gmail_send_test.rb`), not by the grant. Heroku and CI read the same JSON from `GOOGLE_SERVICE_ACCOUNT_JSON`, which wins over the `op` read. A different lane from `gmail.studio.agents` (`studio-agents`, the read-only `Gmail::*` capture lane). **ONE key serves EVERY workspace, and whose mailbox it opens is now DATA, not a constant.** Domain-wide delegation cannot be narrowed at the grant — it authorizes impersonation of any user in a domain and the caller picks the subject — so the boundary is the `workspace_accounts` table: `Workspace::Credentials` refuses to build an authorizer for any subject that is not an **active** row there. (Until 2026-09-19 this was the frozen constant `Workspace::Credentials::SUBJECT`, pinned to `team@mcritchie.industries`; going multi-tenant turned it into an allow-list, so a rotation reader looking for that constant will not find one.) The house convention is `team@<domain>`, validated to belong to its own row's domain. Further addresses we may DRAFT as (`alex@<domain>` and the like) are `workspace_mailboxes` rows, each proven by its own token via `bin/rails 'workspace:check_mailbox[<address>]'` and shut automatically when their workspace is revoked or severed. A mailbox row opens that address's MAIL only (purpose `:mail`); Drive is reachable only as the workspace's own subject (purpose `:workspace`), enforced in `Workspace::Credentials.authorizer_for` because the grant cannot express it. Per domain: register it, have THAT domain's super-admin grant the four scopes to this key's client id, then prove it — `bin/rails 'workspace:check[<domain>]'`, which flips the row active only on a real token. `bin/rails workspace:accounts` lists who is reachable; `bin/rails 'workspace:revoke[<domain>,<why>]'` is the local kill switch, and nothing reactivates a revoked row automatically — `workspace:reinstate` returns it only to *pending*, where the grant must be proven again. **Revoking locally does not withdraw the Google-side grant**; only that domain's super-admin can, by removing this key's client id. | McRitchie Studio `Workspace::{DriveClient,GmailClient}` |
| `agent.solana` | `studio-agents` | Legacy Xan Solana wallet `F6f8…` (the identity was called "Alex Bot" until 2026-09-15); off both live `VaultState` signer sets since the 2026-06-02 key rotation (devnet by `update_signers`, mainnet by redeploying to a new program) and off the devnet Squad since 2026-06-06, and superseded by `agent.xan.solana` below. Carries no `private key` field (verified 2026-09-14), so this item cannot sign anything — but the key leaked, so treat any on-chain seat it holds as live. **KEPT ON PURPOSE** — it backs seed data and devnet test fixtures, so it is not a deletion candidate; what is retired is its place on the live multisigs, and it must never be put back on one. **Since 2026-09-16 it holds no Squads seat and no upgrade authority on either cluster.** That evening Alex closed the first mainnet program `mnzow…` (vault transaction #1, 8:27 PM MDT) and removed `F6f8…` from its Squad `9dCLM…` (config transaction #2, 8:38 PM MDT); `9dCLM…` is now `7ZDJ…` alone. Its bytes survive in two `VaultState` accounts: `mnzow…`'s, which can never act because the program is closed, and the orphaned devnet program `Dx8u…`'s, which is still open, so there it remains a live signer, over only worthless devnet test tokens. | Seed + devnet test use |
| `agent.xan.solana` | `studio-agents-admin` | The **Xan** signer (`8K81…`) — the rotated replacement for `agent.solana` above, renamed from `agent.alex.solana` and MOVED out of `studio-agents` on 2026-09-15. NOT Alex's Phantom wallet (`7ZDJ…`), which has no item in any vault. Read it under `source ~/.zprofile.admin`; the field label is SPACED (`private key`), verified 2026-09-15. One turf-vault consumer still spells the OLD identity, and it is code, not stale prose: `squad.json` → `members.alex_bot`, which is the `VaultState` signer set, not Squads membership. **`squad-upgrade.js` signs with this key on DEVNET only.** turf-vault `280cebf` (2026-09-15) rebuilt the script around the seat roster in `scripts/lib/squad-clusters.js` (`AGENT_SEATS`): this item is devnet's `xan` seat, and the mainnet roster does not list it. The script no longer loads `ALEX_BOT_KEY` or `MASON_KEY`. Squads membership agrees: two config ceremonies on 2026-09-15 — devnet 09:41:25 MDT (transaction #16), mainnet 09:46:51-55 MDT (transaction #3), five minutes apart and NOT one transaction — REMOVED `8K81…` from **both** Squads, and devnet transaction #18 **added it back** at 14:02:10 MDT; mainnet has no such transaction (read at `finalized` 2026-09-16). So on devnet `8K81…`, `2eGs8G3w…` and `BLSBw8…` give the script its threshold of 3, and on mainnet `8K81…` has no seat. ⚠ **A devnet `--send` cannot read this item as the script ships.** `loadSeatKeypair` reads `op://$MCR_OP_VAULT_AGENT/…` with a `studio-agents` default, and this item lives in `studio-agents-admin`; set `SQUAD_KEY_XAN` from an admin-lane read instead. Pointing `MCR_OP_VAULT_AGENT` at the admin vault is no fix, because the other two devnet seats live in `studio-agents` (read from source on `accepted`, not run). **What this item IS still good for:** it is the value of `SOLANA_ADMIN_KEY` on `turf-monster-mainnet`, and `8K81…` is still a live `VaultState.signers` entry (2-of-3, unchanged on both clusters) — a DIFFERENT authority from the Squads multisig, which is why one moved and the other did not. It is NOT the agent's Turf Monster admin identity; that is `solana.turf.admin` below. | Production `SOLANA_ADMIN_KEY`; `VaultState` cosign; devnet Squads upgrade seat (`squad-upgrade.js --cluster=devnet`). **Not** mainnet upgrades |
| `agent.mason.solana` | `studio-agents` | Mason's vault signer (`CytJ…`) — **no longer a Squads V4 member**, still a `VaultState.signers` entry. The two 2026-09-15 config ceremonies (devnet 09:41:25 MDT, mainnet 09:46:51-55 MDT) removed him from BOTH Squads — re-verified absent from each account at `finalized` — and the rebuilt `squad-upgrade.js` no longer names him (turf-vault `280cebf` removed its `MASON_KEY` load). His last Squads seat went on 2026-09-16: config transaction #2 on the retired first mainnet Squad `9dCLM…` removed `CytJ…` together with the leaked `F6f8…`. The same ceremonies removed Xan (`8K81…`) from both as well, but devnet transaction #18 re-seated Xan that afternoon, so today Mason is off both Squads while Xan is seated on devnet and absent on mainnet; do not read the two end states as one event. Mason remains one of the three live `VaultState.signers` (2-of-3, unchanged), which is a separate authority — see the two-authority note under `solana.turf.admin`. | `VaultState` cosign. **Not** Squads approvals |
| `agent.mack.solana` | `studio-agents` | Mack's agent wallet — **not** a Squads member and **not** a `VaultState.signers` entry (verified 2026-09-14) | agent wallet |
| `solana.turf.admin` | `studio-agents` | **The agent governance identity** — `BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo`, item id `2xrfvfho2txchqtem565wmmmfu`. Agent-readable, which is the point: both of the agent's keys now sit in a vault it can open, which is honest rather than merely restricted. Field labels are HYPHENATED (`wallet-address`, `private-key`) where the older `agent.*` items use spaces — verified 2026-09-15 by deriving the public key from the stored private key. Same wallet the old `agent.turf.solana` filed; the item was recreated, the identity was not. **It holds a Squads seat on both clusters.** Re-measured on-chain at `finalized` 2026-09-15: each multisig is **threshold 3 of FIVE members**, all mask 7, and the two clusters do NOT carry the same five — mainnet `4H3fP3ot…` is `7auwTL…`, `3Qj4v9…`, `7ZDJ…`, `9gACbz…` and this key; devnet `7nRuVw3V…` is `2eGs8G3w…`, `3Qj4v9…`, `7ZDJ…`, `8K81…` and this key. **TWO AUTHORITIES, DIFFERENT THRESHOLDS** — Squads (program UPGRADE authority) is five at threshold 3 and live; `VaultState.signers` (treasury/governance — the money) is five at threshold 2 and is the target, still the untouched 2-of-3 (`8K81…`, `7ZDJ…`, `CytJ…`) on-chain until `update_signers` runs. ⚠ They were supposed to differ by `solana.turf.system` being off Squads; **it is not off Squads**, so on mainnet the two sets now carry the same five wallets. This key is in BOTH. A change to one authority is never a change to the other; say *Squads* or *`VaultState`* and never "the multisig" — see **Onchain Admin** in `credentials.md` for the full trade. ⚠ **`3Qj4v9…`, `7ZDJ…` and `9gACbz…` are Alex's PERSONAL wallets, and their Squads seats differ by cluster: `3Qj4v9…` and `7ZDJ…` sit on both, `9gACbz…` on mainnet only, because devnet transaction #18 removed it (read at `finalized` 2026-09-16). All three are deliberately filed in NO vault at all. Never file one into an agent-readable vault to unblock a ceremony.** Read the arithmetic before deciding how strict that rule is: the agent holds this seat by name and reaches `7auwTL…` through the same `studio-agents` vault, which is **two of the three** approvals a mainnet Squads transaction needs. So filing **one** of his wallets hands the agent the threshold outright — not three filings, one. The unblock is always his signature, never a filing. | `turf_monster/qa_rehearsal/key_store.rb` (`turf-admin`); `bin/ecosystem-build` fills local `SOLANA_ADMIN_KEY` from it; the agent's Squads seat |
| `solana.turf.system` | `studio-agents` | **The server operational key, MAINNET** — `7auwTLSvNniSUeAgL6v9RStMXJhWrrUhSJgwFWLpcqC`, item id `hvt5htkgjqsilq5blv3uztqie4`. Hyphenated labels. ⚠ **Read the balance, never a number written here.** It held 0 SOL on mainnet at 09:12 on 2026-09-15 and was funded at 09:20 the same morning; `1000000000` lamports (1.0000 SOL) at `finalized` later that day. It is the intended future value of `SOLANA_ADMIN_KEY` on `turf-monster-mainnet`, and that cutover is a separate task which judges whether the balance is sufficient for **sustained** fee payment, not merely non-zero. ⚠ **IT WAS MEANT NEVER TO BE A SQUADS MEMBER, AND ON CHAIN IT IS ONE** — a full `Initiate|Vote|Execute` member of the mainnet Squad `4H3fP3ot…`, re-measured at `finalized` 2026-09-15 (its devnet twin `2eGs8G3w…` likewise on `7nRuVw3V…`). It is also slot 1 of the five-member `VaultState` target. The reason it should be off Squads is unchanged and still right — it is the app's HOT key, sitting in Heroku config on a running dyno and signing every entry and payout, the most exposed key here and the last that should hold program upgrade authority — but stating that as current fact is what this row did for a day. Removing it is a Squads config transaction, tracked as its own task. On the `VaultState` side, slots 4-5 are NOT in `VaultState.signers`: turf-vault's `accepted` keeps `signers: [Pubkey; 3]` at offset 0 and appends `signers_ext: [Pubkey; 2]` at offset 1443, read through **`all_signers()`**. | Planned `turf-monster-mainnet` `SOLANA_ADMIN_KEY`; `VaultState` cosign. Squads: **seated today, against policy** |
| `solana.turf.system.devnet` | `studio-agents` | **The server operational key, DEVNET/QA** — `2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9`, item id `luzehmyewswpnbgytyawc25sdy`. Hyphenated labels. Intended future value of `SOLANA_ADMIN_KEY` on `turf-monster-qa`. Until that lands, **prod and QA share one key** — their `SOLANA_ADMIN_KEY` digests are identical today, and this split is what finally ends that. Previously rode along on the old `agent.turf.solana` item under `devnet-*` labels; it is now its own item. | Planned `turf-monster-qa` `SOLANA_ADMIN_KEY` |
| `agent.turf.solana` | `studio-agents` | **⚠ TWO ITEMS STILL SHARE THIS EXACT TITLE, both superseded and both awaiting deletion** (verified 2026-09-15): `5ocw3v7bzd5wsvllub3qh6pppa` and `wriypyvp7rn2q2snqizhyaojku`. Their contents moved to the three `solana.turf.*` rows above. A title read matches both and `op` refuses with "More than one item matches", which is why nothing addresses this title any more. **The agent service account is read-only** — deleting them needs Alex (`(101) You do not have permission`, re-measured 2026-09-15), so no code may depend on the deletion happening. `agent.turf.solana.team` (`g6tkfthql3vjmis4zmygo5a5kq`) is in the same queue. | Nothing — pending deletion |
| `agent.managed_wallet` | `studio-agents` | Managed wallet encryption key | Turf Monster managed-wallet flows |
| `agent.helius` | `studio-agents` | Devnet/mainnet Helius RPC URLs | Solana apps |
| `agent.aws.mcritchie-ses` | `studio-agents` | Shared SES-scoped AWS API credentials, region `us-east-2`; runtime SMTP credentials are derived/stored separately | McRitchie, Turf Monster, and future app email delivery |
| `agent.aws` | `studio-agents` | General AWS API credentials (S3 read/write, `us-east-2`); fields `access key` + `access secret key`. One IAM user, `mcritchie-s3`, backs **every** McRitchie app — read **Shared AWS identity** below before rotating or reusing it. Ignore the decoy `dont.use.agent.aws`. | Active Storage + reference-image (e.g. Pokémon) uploads, across hub, Turf Monster, Industries, and moms-app |
| `AWS` | `studio-agents-admin` | IAM user `studio-agents-admin` (account `534727954137`), created 2026-09-01. Fields `access-key` + `secret-access-key` (+ `account-id`, `region` = `us-east-2`). Policy `studio-agents-admin-provisioning`: `s3:*`, mint/rotate IAM users under path `/mcr/*`, account read-only. It sits outside `/mcr/`, so it cannot edit its own policy — that AWS constraint still holds. The 1Password side no longer does: this row said the admin service account's vault grant was READ-ONLY, which contradicted line 35 of this same table and the `credential-filing` SOP. The vault became admin-lane-writable on 2026-09-02 (a new admin service account with read+write), so `op item edit` succeeds and a refusal is now a symptom, not the expected result. | Steffon's `bucket-provision` sessions and fleet audits, via `source ~/.zprofile.admin` + the admin op token. Conventions: `modules/object-storage.md` |
| `Coinbase Developer Platform` | `studio-agents` | CDP API key | Turf Monster CDP ramp |
| `higgsfield.studio.agents` | `studio-agents` | Higgsfield media generation API (`api.higgsfield.ai`). Filed 2026-09-20 under the `<service>.<entity>.<lane>` convention, category `API Credential`. **One field, `api-key`, holding BOTH halves joined by a colon** — `<KEY_ID>:<KEY_SECRET>`. Split on the first colon: before → `HIGGSFIELD_API_KEY`, after → `HIGGSFIELD_API_SECRET`. ⚠ **The console shows no separate secret field, and that is correct, not a missing value** — Higgsfield hands the pair over pre-joined (the `higgsfield-js` SDK calls this form `HF_CREDENTIALS`). Measured 2026-09-20 by length and charset, never revealed: 101 chars = a 36-char UUID + `:` + a 64-char hex secret. The API takes them re-joined as `Authorization: Key <id>:<secret>`, which `app/services/higgsfield/client.rb` already sends from the two env vars, so **no code change is needed**; there is no Bearer or `api-key:` header mode. Supersedes `agent.higgesfield`. | McRitchie Studio content pipeline (`Content::AssetsAgent`, `Content::AssembleAgent`); local `.env` only — `mcritchie-studio` carried no `HIGGSFIELD_*` config on 2026-09-20 |
| `agent.higgesfield (RETIRED - use higgsfield.studio.agents)` | `studio-agents` | **Retired 2026-09-20**, superseded by the row above. It was both the legacy inverted `agent.<service>` form and a misspelling; the `credential-filing` SOP grandfathers legacy names but says to rename one when you next touch it and fix every reference in the same pass — which is what that date was. Its value is kept as a fallback until the replacement key is proven to authenticate, then archive it. **Do not rotate it.** No `op://` lookup resolves it — swept across every repo on disk 2026-09-20, zero hits. The census is now COMPLETE: `.env.example` was repointed at `higgsfield.studio.agents` in the `studio-agents` vault on 2026-09-21 (`point-env-example-at-higgsfield`), and a tripwire (`test/lib/env_example_credential_pointers_test.rb`) now fails the build if any template pointer names a row whose NAME CELL is marked RETIRED or DELETED here. **That discharges the TEMPLATE reason to wait** — a fresh-machine rebuild can no longer read this name out of `.env.example`. **It does NOT discharge the other precondition, stated above: this value is the FALLBACK until the replacement is proven to AUTHENTICATE.** As of 2026-09-20 that verify could not pass — the account answered `not_enough_credits` on every media type (`system/secrets-rotation.md`, Higgsfield §Verify). Archive it once the replacement authenticates, not before. | Nothing at runtime; no reference on disk. Archive once the replacement authenticates — not yet proven |
| `x.api` | `studio-agents` — **absent on 2026-08-29**; the X credentials present there are `agent.turf.x` | X/Twitter API credentials | McRitchie Studio news/content |
| `agent.turf.x` | `studio-agents` | **The live X/Twitter credentials** — described here on 2026-09-22 because `.env.example` now points at it, which is the trigger the section below states. Category LOGIN; five concealed fields, read by label: **`Bearer Token`** → `X_BEARER_TOKEN` (read-only intake), **`Consumer Key`** → `X_API_KEY`, **`Consumer Key Secret`** → `X_API_SECRET`, **`Access Token`** → `X_ACCESS_TOKEN`, **`Access Token Secret`** → `X_ACCESS_TOKEN_SECRET`. Field labels measured 2026-09-22 (`op item get`, labels only, no values revealed); the read+write pair needs an X app with Read and Write permissions. Supersedes `x.api`, which the row above records absent. | McRitchie Studio news intake; Turf Monster Starter Post X workflow (`@turfmonstershow`) |
| `anthropic` | — (not located) | **NOT PRESENT in the vault `.env.example` named.** Swept 2026-09-22 across every vault the agent service account can read — `studio-agents` (44 items), `industries-agents` (1), `family-agents` (0), `Commercial Welding` (3) — and this item is in none of them. `studio-agents-admin` and `studio-applications` are invisible to that token by design, so this records where it is NOT, not that it does not exist. The template used to say "in agents vault", a vault that has not existed since the 2026-08-28 rename; it now says the value comes from the provider console. **File a row with a real vault the day it is filed** — until then a rebuild gets `ANTHROPIC_API_KEY` from console.anthropic.com. | McRitchie Studio AI chat, News refine/conclude agents, Content metadata (`ANTHROPIC_API_KEY`) |
| `🐊 TikTok` | — (not located) | **NOT PRESENT in the vault `.env.example` named** — same 2026-09-22 sweep and the same caveat as `anthropic` above. The template's "in agents vault" clause named a vault retired on 2026-08-28. The TikTok app was still in review when the template was written (submitted 2026-05-04, sandbox works for the app owner only), which is the likeliest reason it was never filed. | Turf Monster Starter Post TikTok workflow (`TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET`) |

### Also present in `studio-agents` (listed 2026-08-29, not yet described)

Beyond the rows above: `agent.1password` (holds the
service-account token install recipe), `agent.rails_master_key`,
`agent.resend`, `agent.google`, `Google | McRitchie Studio`, `agent.gmail`,
`agent.rubygems`, `agents.cloudflare`, `agent.ipinfo.io`, `agent.coinflow`,
`agent.stripe`, `agent.stripe.sandbox`, `turf.stripe`, `Moonpay`,
`turf.squad`, `turf_vault-mainnet-keypair` (document),
`discord.webhooks`, `dont.use.agent.aws` (decoy — ignore). Describe an item
in the table above the first time a doc or script depends on it.

## GitHub App IDs — identifiers, not secrets

| App | 1Password item | Vault | `app-id` |
|-----|----------------|-------|----------|
| agent (build/review) | `github.mcritchie-agent` | `studio-agents` | **`4431410`** |
| deployer (ship) | `github.mcritchie-deployer` | `studio-agents-admin` | **`4431542`** |

A convenience copy sits at `~/.config/mcritchie/app-ids.json` on
Alex's Mac. Nothing generates that file, so a rebuilt machine will not
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
brands is Alex's deliberate choice; this section records what that
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
| `mcritchie-industries-production` | `mcritchie-industries` (per-app key since 2026-09-02); `mcritchie-industries-qa` Active Storage was CUT OVER to the dev bucket 2026-09-02 (`/tasks/industries-qa-bucket-cutover`), but its `Studio::S3` writers (`/admin/emails`, `/admin/knowledge`) STILL resolve this bucket and are still refused here — `Studio::S3.environment` reads `Rails.env`, not `QA_ENV` | **No** — flipped private 2026-09-01 while still empty |
| `mcritchie-industries-dev` | Industries dev | **No** — flipped private 2026-09-01 while still empty |
| `moms-app-production` | moms-app (deployed off the hub Heroku account) | **No** — the one private bucket |

**Where the value lives.** 1Password, plus each deployed consumer's
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` config vars. As of 2026-08-13 only
`mcritchie-studio` and `turf-monster-mainnet` carry them, and both are identical
to the 1Password item. Industries' deployed apps carry per-app tier-4 keys
instead (set 2026-09-02 — see **First migration landed** below), so Industries
never joins this rotation list.

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

**First migration landed 2026-09-02:** Industries' deployed apps now run
`mcr-mcritchie-industries-{prod,dev}` via Heroku config vars and are OFF this
shared identity's rotation list. The prod pair is filed as
`mcritchie-industries.aws` in `studio-applications` (the applications vault
superseded the earlier plan of `agent.mcritchie-industries.aws` in
`industries-agents`). The **dev pair is still owed** — QA carries no AWS config
vars, so its values live only in local `.env` files; file them into the same
item as `dev-access-key`/`dev-secret-access-key` when next at a desk that has
them.

## Convention

Use `agent.<name>.<service>` for agent-owned identities, and clear product names for third-party integrations where a vendor UI uses that name.

Examples:

- `agent.steffon.aws`
- `agent.jasper.solana`
- `Coinbase Developer Platform`

When a credential is shared by every agent, prefer a product/integration item name over pretending one character owns it.
