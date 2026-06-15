# McRitchie Ecosystem

Single orientation surface for the McRitchie stack. Fresh contributors, fresh agent sessions, and future-you start here.

## The Repos

| Repo | Role | Stack | Port |
|------|------|-------|------|
| [`mcritchie-studio`](https://github.com/amcritchie/mcritchie-studio) | Flagship hub. Task/News/Content pipelines, NFL data, auth-capable Studio app, and ecosystem recovery scripts. | Rails 7.2 / Postgres | 3000 |
| [`turf-monster`](https://github.com/amcritchie/turf-monster) | Sports pick'em (World Cup 2026). Solana onchain via turf-vault. | Rails 7.2 / Postgres / Redis / Sidekiq | 3100 |
| [`chain-ops`](https://github.com/amcritchie/chain-ops) | Planned Solana environment control plane. Starts with localnet validator support. | Rails 7.2 / Postgres | 3300 |
| [`studio-engine`](https://github.com/amcritchie/studio-engine) | Shared Rails engine: passwordless auth, error logging, theme, modals, ImageCache. | Ruby gem | — |
| [`solana-studio`](https://github.com/amcritchie/solana-studio) | Ruby Solana client: RPC, ed25519, borsh, tx builder. | Ruby gem | — |
| [`turf-vault`](https://github.com/amcritchie/turf-vault) | Onchain escrow vault. 2-of-3 multisig. Consumed by turf-monster. | Anchor / Rust / Solana | — |

`rolio` exists locally as a prototype app, but it is not yet in the managed ecosystem registry. `tax-studio` remains reserved at `3200-3299` and `chain-ops` is planned at `3300-3399` in `config/satellites.yml`; if Rolio joins the managed stack, assign it `3400-3499` and move its primary port to `3400`.

## Dependency graph

```
studio-engine gem ──┐
                    ├──> mcritchie-studio (flagship)
                    ├──> chain-ops ───────> solana-studio gem
                    └──> turf-monster ────> solana-studio gem
                                       ──> turf-vault (devnet + mainnet deployments)
```

The Rails apps consume `studio-engine` and `solana-studio` from RubyGems. Local clones are still part of the ecosystem because agents edit, release, and audit those gems.

## Where to start

| If you're… | Read first |
|------------|-----------|
| Setting up a fresh Mac | [`bin/ecosystem-build`](../bin/ecosystem-build) + [`docs/agents/system/house-burn-down.md`](agents/system/house-burn-down.md) |
| Onboarding to the codebase | [`docs/agents/index.md`](agents/index.md), then the app README/runbook/topic docs for the repo you'll touch |
| Hardening or modularizing the stack | [`docs/agents/audits/fresh-final-audit-2026-06-15.md`](agents/audits/fresh-final-audit-2026-06-15.md), then the current app runbooks |
| Adding or promoting an app | [`docs/agents/modules/app-registry.md`](agents/modules/app-registry.md), `bin/register-satellite --list`, then `studio-engine/docs/NEW_APP_SETUP.md` |
| Working on Solana | `turf-monster/docs/SOLANA.md` and `turf-vault/docs/CURRENT_DEPLOYMENT.md` |
| Working on auth | `studio-engine/docs/USER_CONTRACT.md`, `mcritchie-studio/docs/topics/auth-and-sso.md`, and `turf-monster/docs/AUTH.md` |

## Per-repo summary

- **mcritchie-studio** — The hub. Runs the NFL data ingest pipeline (Nflverse → Spotrac → ESPN → PFF → depth chart), News pipeline (intake → review → process → refine → conclude), and Content pipeline (idea → hook → script → assets → assembly → posted). Owns `bin/ecosystem-build`, the recovery protocol, and the agent-neutral documentation source.
- **turf-monster** — Satellite product app. Sports pick'em UI + contest grading + Solana onchain settlement against `turf-vault`. Read: `README.md`, `docs/LOCAL_STACK.md`, and the topic files in `docs/` (`AUTH.md`, `SOLANA.md`, `FORMULAS.md`, `UI_PATTERNS.md`, `world_cup_2026.md`).
- **chain-ops** — Planned satellite control plane for Solana environments. V1 manages a local `solana-test-validator` and prints the localnet env contract Turf Monster needs for local on-chain work. Read: `README.md`.
- **studio-engine** — Engine. Provides `Studio::ErrorHandling` concern, ErrorLog model, passwordless auth primitives, theme system (7 role colors → CSS vars), modals, ImageCache, and reusable components. Consumed by mcritchie-studio + turf-monster + future apps. Read: `README.md` and `docs/`.
- **solana-studio** — Gem. Primitives only: `Solana::Client` (JSON-RPC), `Solana::Borsh`, `Solana::Transaction` (Anchor discriminators + PDA derivation), `Solana::SplToken`, `Solana::Keypair`. Pure Ruby, ed25519 the only external dep. Consumed by turf-monster (which extends `Solana::Keypair` locally for encryption). Read: `README.md` + `RUNBOOK.md`.
- **turf-vault** — Anchor program. 22 instructions, 2-of-3 multisig on all sensitive ops, Squads upgrade authority. Live devnet/mainnet identity is in `docs/CURRENT_DEPLOYMENT.md`; current proof checklist is in `docs/VERIFICATION_MATRIX.md`. Read: `README.md`, `RUNBOOK.md`, and `docs/CURRENT_DEPLOYMENT.md`.

## Secret + service surface

- **1Password account**: `alex@mcritchie.studio` (`MWOV5OT5BRHATI4EGMN26C5DPA`), vault `agents`. Service-account token bootstraps everything else via `bin/setup-1pass-token`.
- **Heroku apps**: `mcritchie-studio` → https://app.mcritchie.studio; `turf-monster-mainnet` → https://app.turfmonster.media. `RAILS_MASTER_KEY` shared across apps via Heroku config.
- **Solana**: devnet via Anza CLI (`release.anza.xyz/stable/install`). Local dev keypair at `~/.config/solana/id.json` — NOT one of the agent vault wallets. Agent wallets (Alex Bot / Mason / Mack / Turf Monster) stay in 1Password.
- **AWS S3**: per-app buckets (`mcritchie-studio-{dev,production}`, `turf-monster-{dev,production}`) for ImageCache.
- **AWS SES**: shared transactional email target. `studio-engine` owns transport selection plus `Studio::Email.deliver`; McRitchie uses `studio_email_deliveries`, while Turf routes the same facade into its existing `email_deliveries` table. The cross-app sender matrix, SES checklist, local inbox proof rules, and rollback policy live in `docs/agents/modules/email-operations.md`; credential item names live in `docs/agents/modules/credential-inventory.md`. Current proof: both sending domains are verified with DKIM success, but the SES account remains sandboxed; see `docs/agents/audits/ses-production-proof-2026-06-14.md`.

## Recovery in 4 commands

On a fresh Mac with Homebrew installed:

```bash
git clone https://github.com/amcritchie/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio
bin/ecosystem-build       # Phase 1-3: installs toolchain, bails at Phase 4 needing 1P token
bin/setup-1pass-token     # paste 1P token to clipboard first
bin/ecosystem-build       # Phase 4+: pulls .env from Heroku, clones siblings, bounces servers
```

Full protocol: [`docs/agents/system/house-burn-down.md`](agents/system/house-burn-down.md).

## Current audit + roadmap

The current final audit is [`docs/agents/audits/fresh-final-audit-2026-06-15.md`](agents/audits/fresh-final-audit-2026-06-15.md). The prior closeout audit is [`docs/agents/audits/final-closeout-2026-06-14.md`](agents/audits/final-closeout-2026-06-14.md), and the broader roadmap audit is [`docs/agents/audits/broader-ecosystem-audit-2026-06-14.md`](agents/audits/broader-ecosystem-audit-2026-06-14.md). The earlier post-cleanup, ecosystem, and modularization passes remain at [`docs/agents/audits/post-cleanup-ecosystem-audit-2026-06-14.md`](agents/audits/post-cleanup-ecosystem-audit-2026-06-14.md), [`docs/agents/audits/main-ecosystem-audit-2026-06-13.md`](agents/audits/main-ecosystem-audit-2026-06-13.md), and [`docs/agents/audits/modularization-audit-2026-06-13.md`](agents/audits/modularization-audit-2026-06-13.md). Older audits under `docs/agents/system/` are historical snapshots unless their findings have been promoted into active modules or app runbooks.

---

*Last updated: 2026-06-15. Update when repos, ports, production URLs, deploy targets, or agent entrypoints change.*
