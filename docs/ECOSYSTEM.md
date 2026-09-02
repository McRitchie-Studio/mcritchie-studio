# McRitchie Ecosystem

Single orientation surface for the McRitchie stack. Fresh contributors, fresh agent sessions, and future-you start here.

## The Repos

| Repo | Role | Stack | Port |
|------|------|-------|------|
| [`mcritchie-studio`](https://github.com/McRitchie-Studio/mcritchie-studio) | Flagship hub. Task/News/Content pipelines, NFL data, auth-capable Studio app, and ecosystem recovery scripts. | Rails 8.1 / Postgres | 3000 |
| [`turf-monster`](https://github.com/McRitchie-Studio/turf-monster) | Sports pick'em (World Cup 2026). Solana onchain via turf-vault. | Rails 8.1 / Postgres / Redis / Sidekiq | 3100 |
| [`rolio`](https://github.com/McRitchie-Studio/rolio) | Relationship operating workspace. Release-managed standalone app with hosted QA/prod Heroku lanes. **Dormant** since the 2026-07-03 audit. | Rails 8 / SQLite demo runtime | 3300 |
| [`chain-ops`](https://github.com/McRitchie-Studio/chain-ops) | Planned Solana environment control plane. Starts with localnet validator support. | Rails 8.1 / Postgres | 3400 |
| [`studio-engine`](https://github.com/McRitchie-Studio/studio-engine) | Shared Rails engine: passwordless auth, error logging, theme, modals, ImageCache. | Ruby gem | — |
| [`solana-studio`](https://github.com/McRitchie-Studio/solana-studio) | Ruby Solana client: RPC, ed25519, borsh, tx builder. | Ruby gem | — |
| [`turf-vault`](https://github.com/McRitchie-Studio/turf-vault) | Onchain escrow vault. 2-of-3 multisig. Consumed by turf-monster. | Anchor / Rust / Solana | — |

📇 `rolio` is **release-managed standalone with reserved satellite range**:
hosted QA/prod deploys ride `config/release_repos.yml` and
`config/qa_environments.yml`, while `config/satellites.yml` protects `3300-3399`
with `status: reserved`. It is not an active Studio Engine SSO satellite and is
not managed by the rebuild script or hub navbar until deliberately promoted.
`tax-studio` remains planned at `3200-3299`, and `chain-ops` is planned at
`3400-3499`.

## Dependency graph

```
studio-engine gem ──┐
                    ├──> mcritchie-studio (flagship)
                    ├──> chain-ops ───────> solana-studio gem
                    └──> turf-monster ────> solana-studio gem
                                       ──> turf-vault (devnet + mainnet deployments)
```

**Two templates, and the graph shows them.** `studio-engine` is the BASE every app
is built on; the `solana-studio` arm is the WEB3 ADD, bolted on only for a Solana
app. `chain-ops` is being deprecated, so turf-monster is the web3 arm that
remains. See [`docs/agents/system/app-templates.md`](agents/system/app-templates.md)
for the decision and its reasoning.

The Rails apps consume `studio-engine` and `solana-studio` from RubyGems. Local clones are still part of the ecosystem because agents edit, release, and audit those gems.

## Where to start

| If you're… | Read first |
|------------|-----------|
| Setting up a fresh Mac | [`bin/ecosystem-build`](../bin/ecosystem-build) + [`docs/agents/system/house-burn-down.md`](agents/system/house-burn-down.md) |
| Onboarding to the codebase | [`docs/agents/index.md`](agents/index.md), then the app README/runbook/topic docs for the repo you'll touch |
| Hardening or modularizing the stack | [`docs/agents/audits/final-closeout-2026-06-17.md`](agents/audits/final-closeout-2026-06-17.md), then the current app runbooks |
| Adding or promoting an app | [`docs/agents/system/new-app-onboarding-sop.md`](agents/system/new-app-onboarding-sop.md) (tier decision), then [`docs/agents/modules/app-registry.md`](agents/modules/app-registry.md), `bin/register-satellite --list`, and `studio-engine/docs/NEW_APP_SETUP.md` |
| Deciding whether an app is web2 or web3 | [`docs/agents/system/app-templates.md`](agents/system/app-templates.md) — the BASE template (`studio-engine` + `mcritchie-studio`) applies to every app; the WEB3 ADD (`solana-studio` + `turf-monster`) bolts on only for a Solana app |
| Working on Solana | `turf-monster/docs/SOLANA.md` and `turf-vault/docs/CURRENT_DEPLOYMENT.md` |
| Working on auth | `studio-engine/docs/USER_CONTRACT.md`, `mcritchie-studio/docs/topics/auth-and-sso.md`, and `turf-monster/docs/AUTH.md` |

## Per-repo summary

- **mcritchie-studio** — The hub. Runs the NFL data ingest pipeline (Nflverse → Spotrac → ESPN → PFF → depth chart), News pipeline (intake → review → process → refine → conclude), and Content pipeline (idea → hook → script → assets → assembly → posted). Owns `bin/ecosystem-build`, the recovery protocol, and the agent-neutral documentation source.
- **turf-monster** — Satellite product app. Sports pick'em UI + contest grading + Solana onchain settlement against `turf-vault`. Read: `README.md`, `docs/LOCAL_STACK.md`, and the topic files in `docs/` (`AUTH.md`, `SOLANA.md`, `FORMULAS.md`, `UI_PATTERNS.md`, `world_cup_2026.md`).
- **rolio** — Release-managed standalone app. Uses the studio task board,
  PR-review discipline, QA Heroku app (`rolio-qa`), and prod Heroku app
  (`rolio-prod`), but owns its runtime and does not consume `studio-engine`.
  **Dormant** since the 2026-07-03 audit: board tasks archived, dependabot
  config removed, and the Heroku dynos stay up pending Mr. McRitchie's own
  shutdown. Read: `README.md` and `docs/RUNBOOK.md`.
- **chain-ops** — Planned satellite control plane for Solana environments. V1 manages a local `solana-test-validator` and prints the localnet env contract Turf Monster needs for local on-chain work. Read: `README.md`.
- **studio-engine** — Engine. Provides `Studio::ErrorHandling` concern, ErrorLog model, passwordless auth primitives, theme system (7 role colors → CSS vars), modals, ImageCache, and reusable components. Consumed by mcritchie-studio + turf-monster + future apps. Read: `README.md` and `docs/`.
- **solana-studio** — Gem. Primitives only: `Solana::Client` (JSON-RPC), `Solana::Borsh`, `Solana::Transaction` (Anchor discriminators + PDA derivation), `Solana::SplToken`, `Solana::Keypair`. Pure Ruby, ed25519 the only external dep. Consumed by turf-monster (which extends `Solana::Keypair` locally for encryption). Read: `README.md` + `RUNBOOK.md`.
- **turf-vault** — Anchor program. 22 instructions, 2-of-3 multisig on all sensitive ops, Squads upgrade authority. Live devnet/mainnet identity is in `docs/CURRENT_DEPLOYMENT.md`; current proof checklist is in `docs/VERIFICATION_MATRIX.md`. Read: `README.md`, `RUNBOOK.md`, and `docs/CURRENT_DEPLOYMENT.md`.

## Secret + service surface

- **1Password account**: `alex@mcritchie.studio` (`MWOV5OT5BRHATI4EGMN26C5DPA`). Two vaults, two tokens: `studio-agents` (agent lane, `OP_SERVICE_ACCOUNT_TOKEN`) and `studio-agents-admin` (ship lane, a separate `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` — `bin/setup-1pass-token --admin`). The agent token bootstraps everything else via `bin/setup-1pass-token`; `bin/lib/op_vaults.rb` is the map.
- **Heroku apps**: `mcritchie-studio` → https://mcritchie.studio; `turf-monster-mainnet` → https://turfmonster.media; `rolio-prod` → https://rolio-prod-82e96784b462.herokuapp.com. `app.mcritchie.studio` and `app.turfmonster.media` remain legacy Rails aliases, `v1.mcritchie.studio` is the previous McRitchie Studio Squarespace site, `v1.turfmonster.media` is the previous Turf Monster landing site, and QA runs at `qa.mcritchie.studio` / `qa.turfmonster.media` / https://rolio-qa-58beede9dc0b.herokuapp.com. `turf.mcritchie.studio` is retired and answers HTTP 000 — never smoke-test Turf Monster there; see `docs/agents/modules/deployment.md` § Retired Host. `RAILS_MASTER_KEY` shared across Studio/Turf apps via Heroku config; Rolio uses its own `SECRET_KEY_BASE`.
- **Solana**: devnet via Anza CLI (`release.anza.xyz/stable/install`). Local dev keypair at `~/.config/solana/id.json` — NOT one of the agent vault wallets. Agent wallets (Alex Bot / Mason / Mack / Turf Monster) stay in 1Password.
- **AWS S3**: per-app buckets (`mcritchie-studio-{dev,production}`, `turf-monster-{dev,production}`) for ImageCache.
- **AWS SES**: shared transactional email target. `studio-engine` owns transport selection plus `Studio::Email.deliver`; McRitchie uses `studio_email_deliveries`, while Turf routes the same facade into its existing `email_deliveries` table. The cross-app sender matrix, SES checklist, local inbox proof rules, and rollback policy live in `docs/agents/modules/email-operations.md`; credential item names live in `docs/agents/modules/credential-inventory.md`. Current proof: both sending domains are verified with DKIM success, but the SES account remains sandboxed; see `docs/agents/audits/ses-production-proof-2026-06-14.md`.

## Recovery in 4 commands

On a fresh Mac with Homebrew installed:

```bash
git clone https://github.com/McRitchie-Studio/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio
bin/ecosystem-build       # Phase 1-3: installs toolchain, bails at Phase 4 needing 1P token
bin/setup-1pass-token     # paste 1P token to clipboard first
bin/ecosystem-build       # Phase 4+: pulls .env from Heroku, clones siblings, bounces servers
```

Full protocol: [`docs/agents/system/house-burn-down.md`](agents/system/house-burn-down.md).

## Current audit + roadmap

The current closeout audit is [`docs/agents/audits/final-closeout-2026-06-17.md`](agents/audits/final-closeout-2026-06-17.md). It supersedes the June 15 fresh final audit for current queue, cleanup, and remaining-docket state. The prior final audit remains at [`docs/agents/audits/fresh-final-audit-2026-06-15.md`](agents/audits/fresh-final-audit-2026-06-15.md), the prior closeout audit remains at [`docs/agents/audits/final-closeout-2026-06-14.md`](agents/audits/final-closeout-2026-06-14.md), and the broader roadmap audit remains at [`docs/agents/audits/broader-ecosystem-audit-2026-06-14.md`](agents/audits/broader-ecosystem-audit-2026-06-14.md). The earlier post-cleanup, ecosystem, and modularization passes remain at [`docs/agents/audits/post-cleanup-ecosystem-audit-2026-06-14.md`](agents/audits/post-cleanup-ecosystem-audit-2026-06-14.md), [`docs/agents/audits/main-ecosystem-audit-2026-06-13.md`](agents/audits/main-ecosystem-audit-2026-06-13.md), and [`docs/agents/audits/modularization-audit-2026-06-13.md`](agents/audits/modularization-audit-2026-06-13.md). Older audits under `docs/agents/system/` are historical snapshots unless their findings have been promoted into active modules or app runbooks.

---

*Last updated: 2026-06-27. Update when repos, ports, production URLs, deploy targets, or agent entrypoints change.*
