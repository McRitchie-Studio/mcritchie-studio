# Pre-Launch Security Audit — Synthesis Report

**Date:** 2026-05-24
**Scope:** turf-monster + mcritchie-studio + studio-engine + solana-studio + turf-vault
**Target:** mainnet, public, real-money launch
**Method:** independent fresh pass across three domains — Jasper (on-chain + Solana client), Carl (Rails app), Steffon (infra/opsec). Prior 2026-05-19 OPSEC audit not referenced.

Per-domain reports:
- [prelaunch-audit-2026-05-24-jasper.md](./prelaunch-audit-2026-05-24-jasper.md)
- [prelaunch-audit-2026-05-24-carl.md](./prelaunch-audit-2026-05-24-carl.md)
- [prelaunch-audit-2026-05-24-steffon.md](./prelaunch-audit-2026-05-24-steffon.md)

---

## Verdict: **BLOCK LAUNCH**

Four Critical findings and eight High findings. Nothing on the Rails business-logic surface is Critical — Carl found defense-in-depth on every money path (server-side gates, Stripe re-fetch, on-chain TX semantic verification, pessimistic locks). The Criticals are split between **on-chain authorization gaps** (Jasper) and **session/perimeter posture** (Steffon).

Estimated fix-to-clear-gate effort: **1–2 focused days.** Two Critical infra items are config changes (minutes). Two Critical on-chain items require a turf-vault program patch + Squads-multisig redeploy + IDL re-pin (multi-hour cycle, well-documented runbook exists).

---

## Consolidated Findings

| ID | Severity | Domain | Title |
|---|---|---|---|
| C1 | **Critical** | Vault | `migrate_user_account` lets any 1-of-3 admin rewrite any UserAccount with no wallet consent |
| C2 | **Critical** | Vault | `set_username` has zero on-chain validation — operator impersonation + reserved-name squatting |
| C3 | **Critical** | Infra | Shared `_studio_session` cookie across SSO hub + turf-monster has NO secure/httponly/same_site on hub |
| C4 | **Critical** | Infra | `config.hosts` unset in both apps — DNS rebinding + Host-header replay against webhook + admin endpoints |
| H1 | High | Vault | Contest accounts not PDA-seed-bound at entry/settle — substitution accepted |
| H2 | High | Vault | Token-funded entries don't increment `entry_fees` — token-only contest w/ `prizes=0` settles to $0 |
| H3 | High | Infra | `SENTRY_DSN` unset in production — no exception observability, no alerting on day 1 |
| H4 | High | Infra | CSP runs `unsafe-inline` + `unsafe-eval` on Phantom-signing UI — one stored-XSS = wallet drain |
| H5 | High | Infra | No rack-attack throttle on `/wallet/withdraw`, `/wallet/stripe_deposit`, `/wallet/moonpay_deposit`, `/contests/:id/prepare_entry`, `/account/change_password`, `/registrations`, `/account/update_username` |
| H6 | High | Infra | mcritchie-studio has no rack-attack at all — SSO hub login is unbounded brute-force |
| H7 | High | Rails | Contest lock-time (`starts_at`) not auto-enforced in `Entry#confirm!` — late-entry edge attack on staggered slates |
| H8 | High | Rails | `TokenPurchaseJob` rescue can flip purchase row to `failed` after successful on-chain mint — operator-confusion / chargeback risk |
| M1 | Medium | Vault | `force_close_vault` missing discriminator check (defense-in-depth) |
| M2 | Medium | Vault | `create_user_account` permissionless — anyone can pre-create + name another wallet's UserAccount |
| M3 | Medium | Vault | Borsh decoders silently truncate on short buffers — operator-book divergence on bad RPC |
| M4 | Medium | Infra | MoonPay payload re-verification deferred (OPSEC-035, pre-mainnet) |
| M5 | Medium | Infra | Stripe webhook idempotency not keyed on `event.id` directly |
| M6 | Medium | Infra | `BYPASS_IDL_CHECK` env-var has no audit trail when used |
| M7 | Medium | Infra | Squads 2-of-3 keys all in single 1Password vault — known single-trust-domain risk |
| M8 | Medium | Infra | No pre-commit secret scanner |
| M9 | Medium | Infra | `customer_email` leaked through `[tokens] webhook.event_payload` log lines |
| M10 | Medium | Rails | No session-token rotation on email change |
| M11 | Medium | Rails | `set_inviter` accepts any slug — fraud vector once referrals pay |
| M12 | Medium | Rails | `StripeDepositJob` likely missing per-iteration crash-recovery `TokenPurchaseJob` has |
| M13 | Medium | Rails | 60s `list_entry_tokens` cache drives sequence allocation — wasted SOL on rare races |
| M14 | Medium | Rails | Dev routes (`/toast_test`, `/seeds_lab`) reachable in production |
| L1–L7 | Low | Mixed | mint not pause-gated; token-direct payer unconstrained; `.unwrap()` panic surface; homoglyph usernames; Borsh integer sibling; AuthVerifier prefix-match; 6-char password floor; no password reset (operational gap) |

Full per-finding evidence (file:line + attack scenario + fix) in the per-domain reports.

---

## Adversarial Walkthroughs by Flow

### Flow 1 — Manual signup / login

**Attack: credential-stuffing → full account takeover**
1. **H6** mcritchie-studio (SSO hub) has no rack-attack — attacker pounds `/users/sign_in` unbounded with leaked-credential lists.
2. On hit, the hub issues `_studio_session` cookie. **C3** — that cookie has no `httponly`, no `same_site`, no `secure` and is scoped to `.mcritchie.studio` — overwriting the hardened cookie turf-monster previously set on the same browser.
3. Attacker now navigates to turf.mcritchie.studio with the cookie. Full session.
4. **H5** no throttle on `/wallet/withdraw` — attacker drains balance immediately.

**Other gaps:**
- L7 — no password reset by design. Once support load arrives, ad-hoc reset paths will appear; pre-launch is the time to build it properly.
- M10 — email change does not rotate session token. Stolen session persists through email-change "recovery" attempts.
- L6 — 6-char password floor.

### Flow 2 — Google SSO

**Mostly clean.** `from_omniauth` correctly refuses to silently auto-link a Google identity to an unverified-email account (OPSEC-005, Carl confirmed). Defense-in-depth gap: `OmniauthCallbacksController` does not cross-check the validator's email against `auth.info.email` — L-tier.

**But:** post-login the session still rides the **C3** unhardened cookie. Google SSO does not save you from the hub cookie problem.

### Flow 3 — Web3 (Phantom) login

**On-chain cryptographic flow is clean.** SIWS-style nonce with host + user-id binding (`Solana::AuthVerifier`), constant-time comparison, single-use nonce, prefix host check (L-tier robustness suggestion only).

**But the post-login attack surface is the most dangerous of the three login modes:**
- **H4** — CSP has `unsafe-inline` + `unsafe-eval` on a UI that holds a Phantom wallet provider. A stored-XSS injection can shadow `window.solana` or `Alpine.store('session')` and silently sign attacker-crafted transactions the *next* time the user confirms a contest entry or a username change.
- **C3** — same cookie hijack applies.

### Flow 4 — Top-up (Stripe → entry tokens)

**Money path is solid:**
- `StripeCheckoutValidator` re-fetches every session from Stripe before mint.
- `with_lock` pessimistic locks on the purchase row.
- Webhook idempotency keys on `stripe_session_id` (M5: should be `event.id` too).
- `BYPASS_IDL_CHECK` boot guard against mainnet IDL drift (M6: no audit trail when used).

**Gaps:**
- **H8** — concurrent webhook re-delivery can land in `TokenPurchaseJob.rescue` AFTER the on-chain mint succeeded, flipping `purchase.status` to `failed`. On-chain is fine (PDA `init` collision prevents double-mint), but the operator audit trail diverges from reality — chargeback liability bait.
- **H5** — no throttle on `/wallet/stripe_deposit` (initiate side); attacker can spin up thousands of incomplete checkouts.
- **M9** — `customer_email` leaks via `[tokens] webhook.event_payload` log lines.

### Flow 5 — Submit entry (web2 — entry token)

**Server-side authorization is solid:**
- `Entry#confirm!` refuses to activate paid entry without `tx_signature` OR `comped: true`.
- Entry-token decrement is atomic via `with_lock`.

**Gaps:**
- **H7 — the launch-blocker for contest integrity.** `Contest#starts_at` is the displayed lock time but `Entry#confirm!` never compares it to `Time.current`. Per-matchup `locked?` covers only individual kicked games — a 6-pick slate with staggered kickoffs (typical for FIFA group stages) lets a user wait until 30 min after stated lock, watch the live scoreboard from already-kicked games, then submit picks weighted by what they just saw. Free information edge over honest entrants.
- **H2** — token entries don't increment `entry_fees`. A `prizes=0` contest of 100% token entries CANNOT pay anything at settle (cap = `entry_fees + prizes = 0`). Operator-promised payouts have zero on-chain backing — users with winning tokens get $0 at settle.

### Flow 6 — Submit entry (web3 — direct USDC)

**On-chain + Rails verification stack is strong:**
- `Solana::TxVerifier` re-fetches every claimed tx_signature from RPC and verifies program ID, instruction discriminator, account ordering, and amount.
- `with_lock` on Entry confirm.

**Gaps:**
- **H1** — Contest account is not PDA-seed-bound in `enter_contest_direct` / `enter_contest_direct_with_token`. A compromised browser extension or compromised middleman could swap Contest A (the one the user intended) for Contest B (cheaper or shorter lock) before submission. Rails `TxVerifier` catches this off-chain (it knows the contest_id it queued), but defense-in-depth demands the on-chain check.
- **H7** still applies — lock-time enforcement is upstream of both web2 and web3 entry paths.

### Flow 7 — Submit payout

**Best-defended flow in the system:**
- Server-determined end-to-end. No user-callable claim endpoint exists (Carl confirmed).
- Settle is 2-of-3 multisig via Squads. Ranks + payout amounts computed server-side, proposed as a multisig TX, two approvals required.
- On-chain `settle_contest` enforces dedup (`seen` Vec), per-entry `status == Active` reentrancy guard, and a total-payout cap of `entry_fees + prizes`.

**Gaps:**
- **H2** — the cap (`entry_fees + prizes`) silently kills token-only contests (see Flow 5).
- **M7 / organizational** — Squads "2-of-3" is operationally single-trust-domain: Alex Bot + Mason keys both in operator's 1Password. If 1Password is compromised, attacker has upgrade authority AND 2-of-3 settle authority. Pre-mainnet must distribute keys across real trust domains.
- **H5** — no throttle on `/wallet/withdraw` initiate side.

---

## Cross-Domain Attack Chains

These compound otherwise-medium findings into critical exposure.

### Chain A — "Account takeover via SSO hub" (combines H6 + C3 + H5)
Brute-force the hub login (unthrottled, H6) → the hub-issued cookie has no flags (C3) → cookie is sent to turf-monster on `.mcritchie.studio` → drain the user's balance through unthrottled `/wallet/withdraw` (H5). Three independently-medium gaps combine into a near-trivial full takeover.

### Chain B — "Forge a transaction the user thinks is something else" (combines H4 + H1 + C3)
Land stored XSS via inline-script CSP gap (H4) → swap the Contest account on the next `prepare_entry` (no on-chain PDA-seed bind, H1) → user signs a transaction Phantom shows for "Contest A" but the program processes against "Contest B" (smaller, cheaper, or already-settled). C3 means the malicious script also sees the session cookie for replay.

### Chain C — "Identity squat the operator" (combines C2 + M2)
Front-run a wallet's first signup by calling `create_user_account` permissionlessly (M2) with `username = "alex_mcritchie"`, no on-chain validation rejects it (C2). On-chain identity for the brand handle is permanently a squatter's; remediation requires program upgrade or admin override.

### Chain D — "Drain a payout window" (combines C1 + M7 dormant)
Latent today. If a future schema bump re-opens the `migrate_user_account` realloc path (C1) AND any one of the three Squads keys is compromised (M7: all three in one trust domain), the attacker iterates UserAccounts and rewrites `balance` / `total_won` via crafted realloc. Settle then pays attacker-controlled accounts within the on-chain cap. The bomb is primed; v0.16 will trip it.

### Chain E — "Late-entry chip-stack with token-only contests" (H7 + H2)
Honest users buy entry tokens, enter early, lock in picks. Attacker waits until 30 min into the staggered kickoffs (H7 — no lock-time enforcement), submits a token-funded entry weighted by live results. Contest settles, attacker wins. But `entry_fees == 0` because all entries were token-funded — settle cap kicks in (H2), nobody gets paid. Operator promised payouts must come out of operator's pocket off-chain. Worst of both worlds: the attacker took the rank, the honest users got $0.

---

## Recommended Pre-Launch Fix Sequence

**Day 1 — perimeter (Steffon's domain, fastest wins):**
1. C3 — copy turf-monster's `session_store.rb` into mcritchie-studio. ~5 min.
2. C4 — set `config.hosts` in both apps' `production.rb`. ~10 min.
3. H3 — provision Sentry, set `SENTRY_DSN` in Heroku config, add to MAINNET_LAUNCH.md step 6. ~30 min.
4. H6 — add rack-attack to mcritchie-studio's Gemfile + initializer (mirror turf-monster's). ~30 min.
5. H5 — extend rack-attack initializer to cover the seven listed endpoints. ~45 min.
6. M14 — guard dev routes in `config/routes.rb` behind `Rails.env.development?`. ~10 min.

**Day 1 — Rails (Carl's domain):**
7. H7 — add `raise if contest.locks_at && Time.current >= contest.locks_at` to `Entry#confirm!`. ~20 min + test.
8. H8 — wrap `TokenPurchaseJob.perform` in `purchase.with_lock` (or re-check `purchase.reload.status` before downgrading). ~30 min + test.

**Day 2 — on-chain (Jasper's domain, requires Squads redeploy):**
9. C1 — add wallet Signer requirement + wallet-field-binding constraint + length whitelist to `migrate_user_account`. Bump program to v0.15.1.
10. C2 — add reserved-prefix list + printable-ASCII guard to `set_username`. (Defer `UsernameRegistry` PDA + rate-limit to v0.16; the minimum check is enough to close the launch gate.)
11. H1 — add `seeds = [b"contest", contest.contest_id.as_ref()], bump = contest.bump` to every Contest account constraint.
12. H2 — make a policy call: either (a) token paths credit `entry_fees` from an operator reserve PDA, or (b) document explicitly that token entries are operator-promised + ensure no contest ships with token entries unless `prizes > expected_max_payout`.
13. Anchor build → write-buffer → set-buffer-authority → `scripts/squad-upgrade.js` → re-pin `EXPECTED_IDL_HASH` from BUILT IDL → deploy turf-monster.

**Day 2 — partial H4 (CSP):**
14. Drop `unsafe-eval`. `unsafe-inline` requires a nonce/hash refactor — at minimum add a `report-uri` and put the full nonce work on the post-launch sprint.

**Defer (post-launch acceptable):**
- M1–M3, M5–M6, M8–M9, M11–M13. L1–L7.
- Squads real-trust-domain split (M7) — must precede ANY mainnet program-upgrade authority transition, but is not strictly needed to ship v1 if you treat the bot key as a single-trust-domain bot until then.

---

## Launch Gate

**Block until C1–C4 + H1–H8 closed.** All 12 are concrete, the fixes are well-scoped, and the existing MAINNET_LAUNCH.md runbook covers the Squads-redeploy cycle. Mediums + Lows can ship as a backlog.

If launching real-money mainnet with any of these open: do not.
