# McRitchie Ecosystem Audit — 2026-05-17

> **ARCHIVE-ONLY AUDIT SNAPSHOT.** This was the May 2026 ecosystem audit that
> kicked off the agent-doc cleanup. Current orientation lives in
> `docs/ECOSYSTEM.md`, `docs/agents/index.md`, and the June 2026 audit files in
> `docs/agents/audits/`.

> **Corrections (added 2026-05-17 during Tier 1 execution):**
> - **Tier 1 #1 was a no-op.** The audit's claim that "ErrorLog is public by default — no auth check" was wrong. The engine's `ErrorLogsController` already has `before_action :require_admin` (line 2), and `Studio::ErrorHandling` provides `require_authentication` as a global default plus `require_admin` for elevated routes. Neither consumer app overrides this. The Explore subagent missed it during the original survey.
> - **Tier 1 #4 renamed `draft → pending`, not `draft → new`.** Rails 7 refuses `:new` as an enum value because it would collide with the `Contest.new` constructor scope. `:pending` was chosen as the smallest-change alternative that still moves away from `:draft` (the inconsistent term the audit flagged). Operator approved the substitution during execution.

**Scope:** 5 repos under `~/projects/` — `mcritchie-studio` (flagship), `turf-monster` (satellite), `studio` (engine), `solana-studio` (gem), `turf-vault` (Anchor program).

**Method:** Structural read of CLAUDE.md / READMEs / `bin/`, recovery doc, engine API, gem surface, Anchor instruction set, and all 4 memory files at `~/.claude/projects/-Users-alex-projects/memory/`.

**Operator answers** (preserved verbatim — these shaped every recommendation below):
- Q1: Keep `bin/ecosystem-build` in the flagship — the flagship *is* the hub.
- Q2: Tag-pin the `studio` engine + CI consumers against engine `main`.
- Q3: Production-grade smart contract + Rails deployment is the goal; testing and security both matter.
- Q4: Share one satellite registry — don't maintain multiple datasets.
- Q5: Keep `web2_/web3_solana_address`; normalize the stage-color palette; normalize stage vocabulary across apps.
- Q6: Improve turf-monster test coverage.
- Q7: Split CLAUDE.md, ensure MD context is indexable + accessible.
- Q8: Build an ecosystem-orientation doc, optimize it for efficiency.
- Q9: Build a `new-app` scaffolder so adding apps is trivial.

---

## Executive Summary

1. **The ecosystem is healthy and unusually well-recovered.** `bin/ecosystem-build` (8 phases, idempotent, ~30s on a warm machine) + `bin/setup-1pass-token` + `house-burn-down.md` is best-in-class for a small ecosystem. Recovery story is a real moat — most solo operators don't have this.
2. **The biggest single liability is documentation, not code.** `mcritchie-studio/CLAUDE.md` is ~448 lines, kitchen-sink, and every fresh Claude session pays the full token tax. The same NFL pipeline knowledge that makes it valuable also makes it the bottleneck. Splitting into topic files (per Q7) is the highest-leverage Tier 1 move.
3. **`studio` engine is the right abstraction but is the most under-governed dep.** Two apps pull from `git: main` with no tags, no changelog, no consumer-CI. As Tax Studio + future apps land, one bad merge silently breaks N apps. Tag-pinning + an engine CI loop (Q2) closes this cleanly.
4. **Turf Monster is production-shaped but not production-ready.** 97 tests / no e2e CI / no error-monitoring webhook / public devnet RPC / single-keypair upgrade authority on `turf-vault`. Real money flows through the multisig already; the surrounding ops envelope needs to catch up.
5. **The "flagship + satellites" model scales to ~5 apps without changes, but only if the satellite list becomes data-driven.** Adding Tax Studio today means hand-editing 4+ files. A small `satellites.yml` consumed by the engine, the navbar, and `bin/ecosystem-build` collapses that to a config change.

**Top single recommendation:** ship the **CLAUDE.md split + ECOSYSTEM.md + satellite registry** together as a single ~1-day batch. Those three changes compound — they make every other recommendation in this doc cheaper to execute.

---

## Findings

### 1. Build & Recovery

**What's working**
- `bin/ecosystem-build` is genuinely idempotent. Phase detection → install-only-what's-missing → verify is the right shape. ~30s on a warm machine, ~25-30 min cold.
- `bin/setup-1pass-token` is the right answer to a real, documented failure class (smart quotes, line-wrap, whitespace artifacts) — the `pbpaste | tr -d '[:space:]'` pattern should be canonical for any future long-secret install.
- `house-burn-down.md` Appendix A (12 gotchas) is the most valuable file in the ecosystem after `bin/ecosystem-build` itself. Every gotcha encodes a past loss.
- Phase ordering (system tools → languages → shell → secrets → repos → DBs → NFL data → Anchor → servers) is correct. The "1Password service token is the bootstrap secret" gate is the right Phase-4 boundary.

**What I'd flag**
- **Recovery doc lives only in the flagship.** Per Q1 we keep it there — but cross-link from every other repo's README so a fresh contributor cloning `turf-vault` first still finds it.
- **macOS-only.** `pbpaste`, `lsof -ti`, `stat -f`, `sed -i ''` (BSD form) — these will fail on Linux. Fine for now (you're the only operator and on Mac), but document it explicitly so a future Linux mirror doesn't get blindsided.
- **`heroku config:get` is the de facto secrets backup.** Smart — it doubles your secret store with no extra system. But if Heroku ever goes down or you migrate off, `.env` recovery has no fallback. Mitigation: have `bin/ecosystem-build` also write a `tmp/env-snapshot-YYYY-MM-DD.json` to local disk on success, gitignored.
- **`bin/ecosystem-build` has a hard ordering assumption around `phase_repos`.** Phase 4 (secrets) writes `.env` files into repo dirs that may not exist yet, then Phase 5 clones them. The script handles this by skipping `.env` writes when the dir is missing — but on cold boot you need *two* runs to land all `.env` files (first run skips, second populates). Worth a one-liner in the README: "First pass clones, second pass populates `.env`."
- **No version pin or hash check on remote installers.** `release.anza.xyz/stable/install` and `sh.rustup.rs` are piped to `sh`. Standard practice but a supply-chain risk worth flagging — pin to a version + sha256 verify if you ever harden this.

### 2. Cross-App Architecture

**What's working**
- Hub-plus-satellites topology at 2 apps is genuinely lean. SSO via shared `SECRET_KEY_BASE` + cookie is simple and works.
- Per-app responsibility split is sensible: hub owns identity + content/news/NFL, satellite owns its domain (contests) + onchain.
- Gems via `Gemfile git:` ref means no version-publishing infra needed for two private gems serving two apps.

**Tensions**
- **Studio engine has no versioning discipline.** `Studio::VERSION = "0.2.4"` exists but no git tags, no CHANGELOG, both consumers point at `main`. The instant Tax Studio lands, one engine merge can break 3 apps simultaneously.
- **No isolation of engine routes.** `Studio.routes(router)` draws into the host app's router. A host defining a conflicting `/logout` silently loses to the engine.
- **Implicit User contract.** The engine calls `user.authenticate`, `user.admin?`, `User.from_omniauth` — no formal contract documented in one place. New app onboarding will hit cryptic NoMethodErrors.
- **Solana split between gem and app-local is good but undocumented.** Gem owns `Client/Borsh/Transaction/SplToken/Keypair (base)`. Turf Monster owns `Config/Vault/Reconciler/AuthVerifier/Keypair (extended with encryption)`. The line drawn is correct (primitives vs program-specific business logic), but no doc says so — a contributor could mistakenly add a new RPC method to the app, not the gem.
- **SSO satellite wiring is hardcoded in `_admin_dropdown.html.erb`.** Per Q4, this should be data-driven before adding a 3rd app.
- **ErrorLog is public by default.** Both Rails apps mount `/error_logs` and `/error_logs/:slug` with no auth check. Backtraces can expose code paths and local-variable values. Production-blocking.

### 3. Naming Consistency

**Kept (per Q5)**
- `web2_solana_address` / `web3_solana_address` — staying as-is. Internal naming, well understood by the operator, rename cost > clarity gain.
- `Solana::Client` (gem class) vs `SolanaStudio` (gem name) — by design, documented in the gem's CLAUDE.md, leave alone.

**To normalize (per Q5)**
- **Shared stage-color palette.** Today News and Content use different colors for similar-positioned stages:

| Position | News        | Content     | Proposed shared role |
|----------|-------------|-------------|----------------------|
| First    | blue=new    | blue=idea   | `stage-fresh` (blue) |
| 2nd      | yellow=reviewed | yellow=hook | `stage-shaping` (yellow) |
| 3rd      | mint=processed | mint=script | `stage-structured` (mint) |
| 4th      | emerald=refined | green=assets | `stage-refined` (emerald) |
| 5th      | violet=concluded | violet=assembly | `stage-cohered` (violet) |
| Posted/Done | —         | emerald=posted | `stage-shipped` (emerald) |
| Archived | gray=archived | gray=reviewed | `stage-closed` (gray) |

Extract these as CSS custom properties in the `studio` engine (`--color-stage-fresh` ... `--color-stage-closed`). Both News and Content badge classes resolve to the same role, eliminating per-pipeline drift.

- **Stage vocabulary across apps.** turf-monster Contest uses `draft → open → locked → settled`; mcritchie-studio Task uses `new → queued → in_progress → done → failed → archived`; News uses `new → reviewed → processed → refined → concluded → archived`. Each domain genuinely needs different stage names, but the *terminal* stages and *first* stages can share vocabulary: standardize `archived` (already used in mcritchie-studio) as the universal terminal-closed state; standardize `new` as the universal first-stage (turf-monster `draft` → `new`). Don't force-fit the middle stages — those are domain-specific.

### 4. Test Infrastructure

**Per Q6, the focus is turf-monster.**

**Current state**
- mcritchie-studio: 418 runs, ~1080 assertions, 5 skips. Healthy.
- turf-monster: 97 runs, 264 assertions. Sparse given the risk profile (real Solana tokens via 2-of-3 multisig).
- turf-vault: 29 Anchor tests (TypeScript / ts-mocha, localnet). Strong coverage on instructions + multisig.
- solana-studio: 3 test files, unit-only — no devnet integration.
- e2e: Playwright present in both Rails apps; `@devnet`-tagged tests skipped by default; no CI runs any of it.

**Recommended turf-monster coverage adds** (prioritized by blast radius):
1. **Solana::Vault deposit/withdraw round-trip** (currently lightly covered).
2. **Reconciler divergence detection** — seed mismatched DB vs onchain state, assert detection + alert path.
3. **Contest grading edge cases**: ties (multiple entries with same score), entry abandoned mid-grade, partial-settlement recovery after multisig failure.
4. **Settlement-failure paths**: insufficient multisig signers, expired pending transaction, cosigner timeout.
5. **SSO wallet-only user**: confirm wallet-only users are explicitly *not* SSO-able and surface a clean error rather than a 500.
6. **`test_solana_stubs.rb` contract test**: assert the `MockTxSignature` prefix matches what `e2e/rpc-mock.js` actually generates, so a one-sided change to either fails loudly at unit time, not via flaky e2e.

Target: roughly double from 97 → ~200 runs, with the new tests concentrated on the Solana boundary.

**CI plan**
- GitHub Actions on every PR for both Rails apps: `bin/rails test` + Playwright excluding `@devnet`. Free tier handles this comfortably.
- Nightly cron job (or weekly) runs `@devnet` Playwright tests with a funded `SOLANA_BOT_KEY` stored as a GH secret. Posts results to a Slack/Discord webhook on failure.
- turf-vault: GH Actions runs `anchor test` on every PR. Already fast (localnet).
- studio engine: per Q2, CI runs *both consumer apps' suites* against the proposed engine `main`. This is the single most valuable CI addition.

### 5. Documentation & Agentic Context

**This is the highest-leverage findings section.**

**Current state**
- `mcritchie-studio/CLAUDE.md` = 448 lines, ~27k tokens. Topic-organized but kitchen-sink. NFL data pipeline alone (Nflverse → Spotrac → ESPN → PFF → depth-chart picker → formation groups → grade pipeline → roster snapshot) is ~40% of the file.
- `turf-monster/CLAUDE.md` = 274 lines + topic files (`docs/AUTH.md`, `SOLANA.md`, `FORMULAS.md`, `UI_PATTERNS.md`, `world_cup_2026.md`, `BOT_API.md`). Pattern works — CLAUDE.md is the reference index, topic files load on demand.
- `studio` engine has a CLAUDE.md but minimal docs. `solana-studio` has an excellent CLAUDE.md. `turf-vault` has README + RUNBOOK.
- No single ecosystem-wide CLAUDE.md or ECOSYSTEM.md exists.
- Memory at `~/.claude/projects/-Users-alex-projects/memory/` has good entries (`mcritchie-ecosystem`, `mac-dev-setup`, `secret-pastes-on-macos`) but is operator-machine-scoped — not in any repo.

**Per Q7+Q8, proposed split** (write all paths relative to `mcritchie-studio/`):

```
docs/
  ECOSYSTEM.md                          (new — single ecosystem entry point, ~50 lines)
  agents/system/
    house-burn-down.md                  (existing — recovery)
    ecosystem-audit-2026-05-17.md       (this doc)
    (existing system docs unchanged)
  topics/                               (new — CLAUDE.md gets split into here)
    nfl-pipeline.md                     (Nflverse + Spotrac + ESPN + PFF + depth chart + roster snapshot)
    nfl-grading.md                      (proprietary pass/run grades, lineup pickers, formation groups)
    news-pipeline.md                    (existing services + agents content moved here)
    content-pipeline.md                 (Content services + Starter Post X + TikTok workflows)
    auth-and-sso.md                     (engine consumption, SSO flow on hub side)
    theme.md                            (Studio theme integration, button system, color tokens)
    data-model.md                       (models, slug FKs, transitions, position ordering)
    routes-and-controllers.md           (route groups, write-action checklist, error handling)
    testing.md                          (rails tests, playwright, fixtures)
    deployment.md                       (Heroku, env vars, DNS, ACM)
CLAUDE.md                               (becomes ~80-line index pointing at the above)
```

The same pattern applied to `turf-monster/CLAUDE.md` (already partially done — keep extending it). Engine + gem CLAUDE.mds stay as-is (already topic-organized within one file, small enough).

**Why this matters for indexing**
- Topic files are individually < 5k tokens. Future Claude sessions read only what they need.
- `CLAUDE.md` becomes a stable orientation surface — it changes less and pays less token tax.
- Each topic file gets a `## When to read this` header so Claude can pattern-match relevance.
- `ECOSYSTEM.md` becomes the canonical "starting fresh" entry point — pointed at by every per-repo README's "First time?" link.

**ECOSYSTEM.md proposed shape** (small — 50 lines, lives in `mcritchie-studio/docs/`):
- The 5-repo table (copy from `house-burn-down.md`)
- The dependency graph (copy from `house-burn-down.md`)
- "Start here" links: `bin/ecosystem-build`, `house-burn-down.md`, this audit
- Per-repo "what it does in 2 sentences + what doc to read next"
- The 1Password / Heroku / Solana keypair pointers (so a fresh session learns the secret surface)
- Last-updated date

Every other repo's README links to it via a single line at the top: *"Part of the McRitchie ecosystem — see [ECOSYSTEM.md](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/ECOSYSTEM.md) for the full map."*

### 6. Scalability

**Adding Tax Studio (port 3003) today requires:**
1. Clone repo, add `tax-studio` to `bin/ecosystem-build` arrays (`SIBLING_REPOS`, `RAILS_APPS`, `HEROKU_APPS`, `RAILS_PORTS`)
2. Edit `_admin_dropdown.html.erb` to add SSO link
3. Add `Studio.configure` block in the new app
4. Heroku app provisioned + shared `RAILS_MASTER_KEY` written to 1Password
5. DNS CNAME
6. Update `house-burn-down.md` table
7. Update memory file `project_mcritchie_ecosystem.md`

**Per Q9, the data-driven fix:**

Create `mcritchie-studio/config/satellites.yml` (or DB-backed `Satellite` model in the engine):

```yaml
satellites:
  - slug: turf-monster
    display_name: Turf Monster
    emoji: "🏈"
    port: 3001
    heroku_app: turf-monster
    production_url: https://turf.mcritchie.studio
    role: viewer
    description: Sports pick'em — Solana onchain
  - slug: tax-studio
    display_name: Tax Studio
    emoji: "📊"
    port: 3003
    heroku_app: tax-studio
    production_url: https://tax.mcritchie.studio
    role: viewer
    description: Tax planning workspace
```

Consumed by:
- `bin/ecosystem-build` (read into the bash arrays via `yq` or a tiny Ruby helper)
- `_admin_dropdown.html.erb` (loop over satellites instead of hardcoding)
- `Studio.satellites` config helper (engine exposes the list)
- `house-burn-down.md` table (generated section from the same file)
- A future `bin/new-app <name>` scaffolder (writes a new satellite entry)

**Proposed `bin/new-app` scaffolder behavior:**
- Prompts for: slug, display name, emoji, port (auto-suggest next free), heroku app name, role.
- Creates the satellite entry in `satellites.yml`.
- Generates a starter Rails app from a template (rails new + `studio` gem in Gemfile + `Studio.configure` initializer + branded login views + `.env.example`).
- Creates the Heroku app via `heroku create`.
- Adds the `RAILS_MASTER_KEY` to 1Password (manual confirmation prompt — token-paste pattern).
- Updates `house-burn-down.md` table via insertion marker.
- Prints DNS instructions.

**Deploy target portability.** Heroku is baked into ~6 places (`bin/ecosystem-build`, both apps' README, `house-burn-down.md`, both CLAUDE.mds, deploy hooks). Moving to Fly/Render would touch all of these. Not urgent — but worth abstracting *deploy provider* as a satellites.yml field so the docs and scripts can branch on it eventually.

### 7. Production Readiness (per Q3)

The two production-readiness questions are quite different. Treating them separately.

#### 7a. `turf-vault` (smart contract → mainnet)

**Current state**
- Deployed to devnet at `7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J`.
- 29 ts-mocha tests against localnet — strong coverage of instructions + multisig.
- Multisig: 2-of-3 signers (Alex Bot / Alex human / Mason) stored in `VaultState`. Settlement, force_close, update_signers all 2-of-3.
- **Upgrade authority is currently a single keypair** (`~/.config/solana/id.json`). This is the single largest production risk — whoever holds that one keypair can ship a malicious upgrade without multisig approval.
- IDL auto-publishes on deploy; no IDL hash verification in turf-monster.

**Recommended path to mainnet** (sequential phases — don't skip):

1. **External audit.** Halborn, Neodyme, OtterSec, or Zellic for a focused Anchor audit. Budget $20-60k for a program this size (~12 instructions, well-scoped). Lead time ~4-8 weeks. Halborn and Neodyme are the most Solana-native; Zellic has strong cryptography depth.
2. **Upgrade authority migration.** Move program upgrade authority from `~/.config/solana/id.json` to a Squads multisig with the same 2-of-3 signers as the vault. `solana program set-upgrade-authority` after deploying Squads. This is the single highest-impact security improvement — same threshold as settlement.
3. **IDL hash pinning.** Embed expected IDL hash in turf-monster `Solana::Config`. On Rails boot, fetch deployed IDL, hash, compare — refuse to start if mismatched. Catches both unintended IDL drift and supply-chain tampering.
4. **Devnet integration test suite.** Today turf-vault tests are localnet-only. Add a small suite (10-15 cases) hitting the *deployed devnet program* from the Rails layer: create_contest → enter_contest → settle_contest → close_contest, with multisig coverage. Run nightly in CI.
5. **Bug bounty.** Immunefi listing post-audit, scaled to TVL. Start at $5-10k max payout; raise as deposits grow.
6. **Mainnet rollout in stages:**
   - Phase A (1-2 weeks): mainnet deploy, *no real users yet*, internal cosign-only smoke contests with $5-10 total at risk.
   - Phase B (4 weeks): real users, per-contest TVL cap of $500-1000, hard daily mint cap.
   - Phase C: lift caps after N (suggest 50) successful settlement cycles with zero divergence.
7. **`force_close_vault` rehearsal.** Practice the recovery instruction on devnet *before* mainnet launch. Document the runbook (which 2 signers, what state changes, when to use it). This is your backstop if the vault schema ever breaks deserialization on mainnet.
8. **Signer rotation playbook.** `update_signers` exists; document the procedure for adding/removing signers, what triggers it (key compromise, team change), and pre-stage a cosign session each quarter to confirm it still works.

**Specific code observations:**
- The `force_close_vault` instruction reading signers from raw account bytes (not deserialized) is a *clever* and *correct* migration backdoor — but the rationale should be in the program's CLAUDE.md so it survives a future contributor's "this looks weird, let me clean it up."
- `remaining_accounts` pattern in `settle_contest` to bypass Anchor's account limit is correct. Add a unit test that asserts the manual PDA verification rejects a spoofed `user_account` PDA — currently relies on the verification existing, not a test that catches its removal.
- Seeds awarded per entry (60 per) are a domain-level magic number embedded in the program. If the seed economy ever changes, that's a program redeploy — confirm this is the intended coupling.

#### 7b. `turf-monster` Rails app (production hardening)

**Current state**
- Deployed to Heroku at `turf-monster`. Sidekiq + Redis active.
- Error logging via `Studio::ErrorLog` — DB-backed, *public viewer with no auth* (production-blocking).
- No external error monitoring (Sentry / Honeybadger / Rollbar).
- Solana RPC via public devnet endpoint — rate-limited under load (gotcha 7 in `house-burn-down.md`).
- Secrets in Heroku config + 1Password. No rotation runbook.

**Recommended production hardening** (parallel work to 7a — most items are days, not weeks):

1. **Lock down `/error_logs`** in both Rails apps. Wrap routes with `require_admin` (or `require_logged_in`) in the engine. Add a config flag `Studio.error_log_visibility = :admin_only` for explicit opt-in to public. *Ship before any production traffic increase.*
2. **Add Sentry (or equivalent).** Send all `Studio::ErrorLog.capture!` events as a side-effect. ErrorLog stays as the in-app triage view; Sentry handles paging/aggregation/release tracking.
3. **Paid Solana RPC.** Switch `SOLANA_RPC_URL` to QuickNode or Helius. Track RPC error rate as a metric.
4. **Solana observability.** Log every onchain TX with signature, amount, contest, wallet. Surface aggregate metrics: TX success rate, settlement latency, reconciler divergence count. Anything beyond a single-digit-per-day divergence pages oncall.
5. **Reconciler scheduling.** Move `Solana::Reconciler` to a Sidekiq cron job (every 15 min). Alert on any DB↔onchain divergence > $0.01.
6. **Rate limiting on entry endpoints.** rack-attack or similar — protect contest entry, deposit, withdraw from self-DoS.
7. **Secrets rotation runbook.** Document how to rotate X tokens, Anthropic key, Higgsfield, TikTok refresh, AWS keys, Solana admin key. None are in `bin/ecosystem-build` flow currently. Each gets: where stored (Heroku + 1Password slugs), how to regenerate at source, how to push to both stores, how to verify.
8. **Pre-deploy gates.** GH Actions runs `brakeman` (already gemified in mcritchie-studio), `bundle-audit`, `bin/rails test`, Playwright. Heroku release phase runs `db:migrate` + a smoke healthcheck endpoint.
9. **DB backup verification.** Heroku Postgres has continuous protection; add a quarterly *restore* test (not just a backup-exists check). Document the procedure.
10. **DDoS / abuse guard for the Solana faucet endpoint** (if it's user-facing) — currently could be drained by a script.

#### 7c. Solana code split (per Q3)

Recommended boundary:

| Currently lives in | Should live in | Rationale |
|---|---|---|
| `turf-monster` `Solana::AuthVerifier` | `solana-studio` gem | Generic ed25519 signature verification for wallet login. No turf-specific knowledge. |
| `turf-monster` `Solana::Keypair` (extends gem's) | Keep app-local extension | Adds AES encryption + DB persistence specifics. App boundary is correct. |
| `turf-monster` `Solana::Config` | Keep app-local | Encodes turf-vault program ID, mints, network. App-specific. |
| `turf-monster` `Solana::Vault` | Keep app-local | Business logic against the deployed turf-vault program. App-specific. |
| `turf-monster` `Solana::Reconciler` | Move *helpers* to gem, keep orchestration app-local | Generic balance-comparison primitives → gem; turf-monster-shaped reconcile loop stays. |
| `solana-studio` gem `Solana::*` | Keep as-is | Right surface for primitives. |

After the split, document the rule in `solana-studio/CLAUDE.md`: *"If it talks to an arbitrary Anchor program: gem. If it talks to turf-vault specifically: app."*

---

## Recommendations (Tiered)

> **Post-execution status (2026-05-23):** Each item below is annotated with ✅ (shipped) or ⏳ (open) based on current repo state and memory. Use this as the live progress tracker; remove the markers only when the underlying check has been re-verified.

### Tier 1 — Quick Wins (ship today, ~half-day each)

| # | Status | Change | Why | Cost | Risk if skipped |
|---|---|--------|-----|------|----|
| 1 | ✅ | Lock down `/error_logs` to admin-only (engine change) | Original "claim" was wrong — engine already enforced `require_admin`. Verified during Tier 1 execution; see correction note at top of this doc. | — | — |
| 2 | ✅ | Add stage-color CSS variables to `studio` engine + use in News + Content badges | Unifies stage vocabulary; cheap aesthetic win | 1 hr | — |
| 3 | ✅ | Cross-link `house-burn-down.md` from every repo's README | Recovery doc findable from any clone | 15 min | — |
| 4 | ✅ | Rename `Contest` stage `draft` → `new` (turf-monster) — landed as `draft` → `pending` (Rails 7 reserves `:new`). | Unifies first-stage vocab across apps | 1 hr + migration | — |
| 5 | ✅ | Write `mcritchie-studio/docs/ECOSYSTEM.md` (~50 lines) | One canonical orientation surface | 1 hr | — |
| 6 | ✅ | Cross-link existing memory files (`mcritchie-ecosystem`, `mac-dev-setup`) to ECOSYSTEM.md | Memory ↔ repo coherence | 10 min | — |
| 7 | ⏳ | Document "first pass clones, second pass populates `.env`" in `bin/ecosystem-build` header + README | Removes a first-time-user surprise | 10 min | Low |
| 8 | ⏳ | Add `tmp/env-snapshot-YYYY-MM-DD.json` write at end of `bin/ecosystem-build` (gitignored) | Heroku-independent secret fallback | 30 min | Medium — single point of failure on Heroku |

### Tier 2 — Cleanup Projects (1-3 days each)

| # | Status | Change | Why | Cost | Risk if skipped |
|---|---|--------|-----|------|----|
| 9 | ✅ | Split `mcritchie-studio/CLAUDE.md` into `docs/topics/*.md` per the plan above | Token-tax-per-session minimized; index lives at `docs/topics/`. 13 topic files now. | 1 day | — |
| 10 | ⏳ | Extract `Solana::AuthVerifier` to gem; document gem/app split rule | Reduces duplication; clarifies boundary | 1 day | Medium — drift risk |
| 11 | ✅ | Build `config/satellites.yml` + consume in navbar + `bin/ecosystem-build` + engine helper | `Satellite` YAML helper landed (see `docs/topics/data-model.md` § Non-AR helpers). | 1-2 days | — |
| 12 | ✅ | Tag `studio` engine releases + pin Gemfile to tag in both apps + add CHANGELOG | Engine on RubyGems since 2026-05-17, consumer Gemfiles use plain `gem "studio-engine", "~> 0.4.0"`. Current: 0.4.10. | 1 day | — |
| 13 | ⏳ | Add GH Actions CI for both Rails apps (rails test + Playwright excluding @devnet) + `studio` engine consumer-CI | Catches regressions before merge | 1-2 days | High |
| 14 | ⏳ | Add ~100 turf-monster tests focused on Solana boundary (per §4) | Production-readiness; multisig confidence. `e2e/devnet-smoke.spec.js` (890+ lines) partially closes — Rails unit tests for Vault + Reconciler still pending. See `turf-monster/docs/TESTS_TO_ADD.md`. | 2-3 days | High for mainnet timing |
| 15 | ⏳ | Sentry integration in both Rails apps; ErrorLog calls fan out | Operational visibility beyond local triage | 1 day | High in production |
| 16 | ⏳ | Lock down engine `User` contract — write `studio/docs/USER_CONTRACT.md`; add boot-time validation in engine that raises clear errors if host's User is missing required methods | Removes a class of NoMethodError debugging | 1 day | Medium |
| 17 | ✅ | Move `Solana::Reconciler` to a Sidekiq cron + alert on divergence | Sidekiq-cron schedule in `config/schedule.yml`; alerts via `RECONCILER_ALERT_WEBHOOK`. | 1 day | — |
| 18 | ✅ | Write secrets-rotation runbook (`docs/agents/system/secrets-rotation.md`) | Shipped — covers 1P / Heroku / Rails / Solana / Anthropic / X / Higgsfield / TikTok / AWS / Google OAuth. MANAGED_WALLET_ENCRYPTION_KEY procedure still pending — see Wave 4 follow-up. | 1 day | — |

### Tier 3 — Architectural Moves (week+ each)

| # | Status | Change | Why | Cost | Risk if skipped |
|---|---|--------|-----|------|----|
| 19 | ⏳ | External `turf-vault` audit (Halborn/Neodyme/Zellic) | Mainnet prerequisite. Tracked as OPSEC-025. | 4-8 weeks + $20-60k | Critical — no mainnet without this |
| 20 | ✅ | `turf-vault` upgrade authority → Squads 2-of-3 (devnet) | Devnet shipped 2026-05-19. Mainnet pending — see `squads-upgrade-authority-migration.md`. | 3-5 days | — (devnet) |
| 21 | ⏳ | Devnet integration test suite for turf-vault (Rails ↔ deployed devnet) + nightly CI | Catches integration drift between Rails and program. Smoke spec exists locally; nightly CI not yet. | 1 week | High for mainnet |
| 22 | ✅ | IDL hash pinning in turf-monster + boot-time verification | `Solana::Config#verify_idl!` gates boot + `assets:precompile` in prod (OPSEC-014). | 2-3 days | — |
| 23 | ⏳ | Mainnet rollout in 3 phases (smoke → capped → uncapped) | Limits blast radius if anything is wrong | 6-8 weeks elapsed | Critical |
| 24 | ⏳ | `bin/new-app <name>` scaffolder (per Q9) | Tax Studio + beyond ships in minutes, not hours. Spec written at `new-app-scaffolder-spec.md`. | 3-5 days | Medium |
| 25 | ⏳ | Abstract deploy provider as `satellites.yml` field; doc Heroku alternatives | Future portability away from Heroku. `Satellite#deploy_provider` field exists in the YAML schema. | 1 week | Low |

---

## Agentic Context — Deep Dive

This section is for things that specifically slow down or trip up fresh Claude sessions. Per the audit prompt's emphasis on this as first-class.

### What's working
- `house-burn-down.md` is exceptionally well-shaped for an LLM consumer — explicit gotchas with "why" + "fix" paragraphs, ordered phases, cross-references at the bottom.
- Memory files at `~/.claude/projects/-Users-alex-projects/memory/` have a strong pattern: `name`, `description`, body with `**Why:**` and `**How to apply:**` lines, `[[wiki-link]]` cross-refs. Re-use this pattern.
- `bin/setup-1pass-token` exists as a self-documenting reference implementation for the "long-secret install" failure class. Future Claude sessions hitting that problem can be pointed at it.

### What slows fresh sessions
1. **`mcritchie-studio/CLAUDE.md` token tax.** ~27k tokens loaded into every session even if the user's question is about, say, theme tokens. Tier 2 #9 fixes this directly.
2. **No single "what is this ecosystem" surface.** A fresh session has to read 5 CLAUDE.mds, 5 READMEs, and `house-burn-down.md` to build a mental map. ECOSYSTEM.md (Tier 1 #5) collapses this to one file.
3. **Implicit conventions never written down.** Examples:
   - "Slug-based FKs, not integer IDs" — written in CLAUDE.md but not in any code comment near the FK definitions.
   - "Studio engine's User contract" — implicit in the engine's controller code.
   - "Solana code split: primitives in gem, business logic in app" — undocumented anywhere.
   Each of these is a class of error a fresh Claude session can make. Writing them down once removes a whole error category.
4. **No write-action checklist surface in turf-monster.** mcritchie-studio's CLAUDE.md has the "New Controller Checklist" — turf-monster doesn't, but it has the same `rescue_and_log` requirement. Port the checklist.
5. **Test-status drift.** mcritchie-studio CLAUDE.md says "418 runs"; the prompt cited "504." Numbers in docs go stale instantly. Replace count-claims with `bin/rails test --count-only` invocations or a CI badge. Or just say "see CI" — fewer numbers to maintain.
6. **Memory ↔ repo coherence.** Memory files reference repo paths; repos don't reference memory files. After ECOSYSTEM.md ships, add a memory entry that just points at it (so any future session learns "the canonical ecosystem doc is at this path"). Already partially handled by `project_mcritchie_ecosystem.md` — extend it.

### What I'd add to memory (after this audit ships)
- `feedback_audit_2026_05_17.md`: "Operator wants to keep `web2_/web3_solana_address` naming as-is. Wants production-grade smart contract path including external audit + Squads upgrade authority. Approves all stage-color normalization." (Captures Q5 decisions so a future session doesn't re-litigate them.)
- `project_satellite_registry.md`: "`mcritchie-studio/config/satellites.yml` is the source of truth for satellite apps. Navbar, ecosystem-build, and the engine all consume it. Adding an app = editing this file (after Tier 2 #11 ships)."
- `project_turf-vault_production.md`: "`turf-vault` mainnet path is gated on external audit + Squads multisig upgrade authority + IDL pinning. Pre-audit, treat all program changes as devnet-only experiments." (Once Tier 3 work begins.)

---

## No-Regrets Renames

Per Q5, `web2_/web3_solana_address` is staying. The list below is *only* the renames that have operator approval (explicit or implied), with the actual sed-able commands. Run from each repo root.

### Stage normalization

```bash
# turf-monster: Contest stage "draft" → "new"
# Code:
grep -rln "draft" app/models/contest.rb app/controllers/contests_controller.rb \
  | xargs sed -i '' "s/'draft'/'new'/g; s/\"draft\"/\"new\"/g"

# DB migration (write manually — don't sed):
# rails g migration RenameContestDraftStageToNew
# (write up + down to update enum default + existing rows)
```

### Stage-color palette (engine)

Add to `studio/app/assets/stylesheets/studio_theme.css` (or wherever `Studio::ThemeResolver` injects):

```css
:root {
  --color-stage-fresh: var(--color-primary-500);     /* blue */
  --color-stage-shaping: var(--color-warning);       /* yellow */
  --color-stage-structured: #6ee7b7;                 /* mint */
  --color-stage-refined: var(--color-success);       /* emerald */
  --color-stage-cohered: #8e82fe;                    /* violet */
  --color-stage-shipped: var(--color-success);
  --color-stage-closed: var(--color-gray-400);
}
```

Then in `mcritchie-studio/app/views/news/_card.html.erb`, `_contents/_card.html.erb` (and any other stage badges): replace per-stage hardcoded `bg-blue-100` / `bg-yellow-100` etc. with role classes that read these vars.

### File rename candidates (none required, but worth knowing)

These are *consistent today* — listing only so a future audit doesn't re-flag them:
- `bin/{setup-1pass-token, ecosystem-build, resume-rebuild, timed-rebuild}` all follow verb-noun. Consistent.
- `Solana::Client` (gem class) vs `SolanaStudio` (gem name) — by-design, documented.
- `Studio::*` namespace — engine canonical. Used consistently.

---

## Decision Log (Q&A)

Preserved verbatim from 2026-05-17 audit interview:

| Q | Decision | Implication |
|---|----------|-------------|
| 1 — Build script location | (a) Keep in flagship — studio IS the flagship | No move; cross-link from other READMEs |
| 2 — Engine versioning | Tag releases + pin Gemfile + CI consumers | Tier 2 #12 + #13 |
| 3 — Production grade | Yes — both smart contract + Rails | §7 + Tier 3 #19-23 |
| 4 — Satellite registry | Yes — one shared dataset | Tier 2 #11 |
| 5a — web2_/web3_ rename | Keep as-is | No rename |
| 5b — Stage colors | Yes — normalize palette | Tier 1 #2 |
| 5c — Stage vocab | Yes — normalize | Tier 1 #4 |
| 6 — Test coverage | Improve turf-monster | Tier 2 #14 |
| 6b — CI plan | (no specific pick — recommending b: PR + nightly @devnet) | Tier 2 #13 |
| 7 — CLAUDE.md split | Yes — indexable + accessible | Tier 2 #9 |
| 8 — ECOSYSTEM.md | Yes — efficient | Tier 1 #5 |
| 9 — new-app scaffolder | Yes — make it easy | Tier 3 #24 |

---

## What To Do Tomorrow

If you do nothing else from this doc, do these in order:

1. **Lock down `/error_logs`** (Tier 1 #1). Production data exposure today, free fix.
2. **Write `ECOSYSTEM.md`** (Tier 1 #5). One hour. Every Claude session benefits.
3. **Split mcritchie-studio CLAUDE.md** (Tier 2 #9). One day. Cuts the per-session token tax in half.
4. **Tag the engine + pin consumers** (Tier 2 #12). One day. Future-proofs you against a Tax Studio breaking from an engine merge.
5. **Start the `turf-vault` audit conversation** (Tier 3 #19). 4-8 week lead time — kick it off now even if mainnet is 3 months out.

Everything else is sequenced behind these.

---

*Audit complete. Re-run quarterly or whenever a new app joins the ecosystem.*
