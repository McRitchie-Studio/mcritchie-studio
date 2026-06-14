# Opsec Audit — Turf Monster + Ecosystem (Pre-Production)

**Date:** 2026-05-19
**Auditor:** Claude (6 parallel investigation agents, code-only review)
**Scope:** turf-vault (Anchor), turf-monster (Rails), studio-engine + solana-studio gems, operational envelope
**Excluded:** Live prod state, DDoS/CDN layer, KYC/AML, settled decisions in `feedback_audit_2026_05_17_decisions.md`
**Cross-references:** [audit RFP](turf-vault-audit-rfp.md), [Squads migration runbook](squads-upgrade-authority-migration.md), [ecosystem audit 2026-05-17](ecosystem-audit-2026-05-17.md), [credentials](credentials.md), [house burn-down](house-burn-down.md)

---

> **Post-audit status (2026-05-23):** Original verdict was "NO-GO for mainnet" with 15 mainnet-blocking + 18 should-have findings. Execution is now substantially advanced:
>
> - **Pre-mainnet hard prerequisites** — 25 of 26 ✅ shipped (see § 8). Only **OPSEC-025** (external Anchor audit) remains. The Heroku env vars listed in § 8 are all set; `bin/audit-env-check` passes.
> - **Should-have HIGH-severity items** — 17 of 18 ✅ shipped. Only **OPSEC-028** (mint_entry_token Rails alert) remains, deferred as a post-launch alerting task.
> - **OPSEC-051–089 backlog** — operational tracking only; non-blocking.
> - **Post-audit additions (§ 8)** — incident-driven findings appended after 2026-05-19. **OPSEC-090** (2026-06-13): non-prod process can transact on live mainnet when all `SOLANA_*` vars are consistently mainnet — open, dev-safety guard not yet built.
>
> Effective verdict today: **GO-pending-external-audit**. The current limiter is OPSEC-025 (the third-party Anchor audit, $20–60k + 4–8 weeks), not the application stack. The original "Go / No-Go" section below is preserved verbatim for traceability.

---

## 1. Executive Summary

### Go / No-Go: **NO-GO for mainnet launch as currently configured**

The stack is impressively coherent for solo-operator scale — multisig wiring is real, IDL pinning code exists, the audit posture is documented. But there are **15 mainnet-blocking findings** that span every layer: the Anchor program has two direct vault-drain paths, the Rails app has at least one one-shot money exfil endpoint (`/wallet/deposit?amount=`), webhook signature verification fails open on missing config, account-merge primitives allow session hijack via OAuth or wallet-link collision, and operational prerequisites (Squads upgrade authority, external audit) remain documented-but-not-done.

The Anchor program has the **cleanest** layer despite being smallest — most of its issues are bounded by 2-of-3 cosign. The Rails layer is the **largest attack surface and the weakest** — accepts client-supplied tx signatures, amounts, and seed counts as authoritative state. The gems layer has **the highest blast radius** — bugs there affect every app simultaneously.

### Top 5 Risks

1. **OPSEC-001 — `WalletsController#deposit` accepts arbitrary `params[:amount]` and dispatches admin USDC transfer to the requester.** On mainnet this is a single authenticated POST away from draining the operator wallet. Likely the most exploitable thing in the stack.
2. **OPSEC-002 — Single-key program upgrade authority** still on `~/.config/solana/id.json`. Squads migration is a documented strict prereq. Without it, every machine holding that file is an arbitrary-code-deployment surface over the live treasury.
3. **OPSEC-003 — Account-merge ID-swap.** Both `link_solana` and OAuth callbacks funnel collisions into `merge_users!`, which performs `min(survivor.id, absorbed.id)` then `set_app_session(survivor)`. A logged-in attacker who triggers a collision (wallet or Google email) becomes the victim's session.
4. **OPSEC-004 — MoonPay webhook fails open** when `MOONPAY_WEBHOOK_KEY` is blank. One missed Heroku config var = unlimited USDC minted to attacker-controlled wallets.
5. **OPSEC-005 — `settle_contest` permits duplicate-entry double payouts.** Compromised admin signer + a fatigued cosigner approving a long settlement vec containing the attacker's `(wallet, entry_num)` twice = direct vault drain. 2-of-3 cosign is the only gate, and the settlement payload is too dense to audit visually.

### Severity Distribution

| Severity | Count | Posture |
|---------:|:-----:|---------|
| CRITICAL | 17    | Mainnet-blocking |
| HIGH     | 28    | Fix before mainnet open (rolling launch acceptable for some) |
| MEDIUM   | 22    | Track + fix within 90 days post-launch |
| LOW      | 17    | Hygiene; ship as backlog |

### One-Sentence Verdict

The system is six fixes away from being launchable to a capped-TVL mainnet smoke phase, and ~20 fixes from a full unconstrained launch — but the foundational SOPs (rate limiting, semantic TX verification, fail-closed defaults) are missing across the entire Rails surface and need to be retrofitted before card funds and on-chain funds meet user-supplied input on a public address.

---

## 2. Critical Findings (Block Production)

### OPSEC-001 — `WalletsController#deposit` accepts arbitrary amount, transfers from admin

- **File:** `app/controllers/wallets_controller.rb:23-44`, calling `Solana::Vault#fund_user` at `app/services/solana/vault.rb:312-321`
- **Originating finding:** SVC-020
- **Exploit:** Any authenticated user POSTs `/wallet/deposit?amount=999999`. The action takes `params[:amount].to_f`, converts to lamports, and invokes `vault.fund_user(current_user, amount)` which signs as admin to transfer USDC out of the operator's ATA into the user's ATA. There is no devnet guard on this action (`Solana::Config.devnet?` check is absent here) and no amount cap.
- **Fix:** Delete the action, or wrap in `raise "Disabled in production" if Rails.env.production?`. The legitimate top-up paths are Stripe checkout + MoonPay; the in-app `deposit` is a dev affordance that does not belong on a money-handling production app.
- **Verification:** `grep -rn 'def deposit' app/controllers/wallets_controller.rb`. Confirm route definition at `config/routes.rb` `resource :wallet do post :deposit end`.

### OPSEC-002 — Single-key program upgrade authority

- **File:** N/A (on-chain state). Upgrade authority for `Dx8u…GaCT` = `4AQMNwhyZtsaCLx3Dv9G5a2rXaJ6M221FYQw6sommRWz` (single keypair, `~/.config/solana/id.json`).
- **Originating finding:** OPS-001 (also referenced VAULT-012, OPSEC ecosystem-audit Tier 3 #20)
- **Exploit:** Any machine with `~/.config/solana/id.json` can ship arbitrary program code over the live vault. RCE on the operator's laptop, a stolen backup, an accidentally-committed key, a Heroku `ps:exec` session = total treasury compromise. The 2-of-3 cosign on settlement/withdraw is bypassed because new program logic can do anything.
- **Fix:** Execute `docs/agents/system/squads-upgrade-authority-migration.md`. Rehearse on devnet first. Documented as strict prereq.
- **Verification:** `solana program show <program_id>` should show `Authority: <Squad vault PDA>`.

### OPSEC-003 — `settle_contest` allows duplicate-entry double payouts

- **File:** `programs/turf_vault/src/instructions/settle_contest.rs:56-102`
- **Originating finding:** VAULT-001
- **Exploit:** Settlement loop iterates `settlements: Vec<Settlement>` with no dedup on `(wallet, entry_num)`. Deserialize→mutate→serialize per iteration means the second pass for a repeated entry reads the first pass's write and credits again. Compromised admin signer + a cosigner approving a 50-entry payload that has the attacker twice = direct drain on next withdraw. Cosign fatigue on long settlements is the load-bearing trust assumption.
- **Fix:** Build a `BTreeSet<(Pubkey, u32)>` during the loop; reject duplicates with a dedicated error. Additionally, require `contest_entry.status == Active` before mutating (prevents settle-then-resettle of the same entry).

### OPSEC-004 — `enter_contest_with_token` burns user tokens without user signature

- **File:** `programs/turf_vault/src/instructions/enter_contest_with_token.rs:13-67`
- **Originating finding:** VAULT-002
- **Exploit:** The `wallet` account is `UncheckedAccount`. Only `payer` (any vault signer, 1-of-3) signs. Token owner does NOT sign. A compromised Alex Bot key iterates `getProgramAccounts` for `EntryTokenAccount{consumed: false}`, then calls `enter_contest_with_token` to burn each user's token into low-prize/already-lost contests. Combined with OPSEC-003, the same key can enter the attacker's wallet into a stuffed contest and settle. Server-subsidized prize pools (intentional v1 gap) mean each burned token destroys ~$19 of user value AND reroutes vault subsidy to the attacker.
- **Fix:** Require `user: Signer<'info>` (mirror `enter_contest_direct_with_token`), OR introduce per-token spend-intent signatures the admin submits on behalf of the user.

### OPSEC-005 — Account-merge ID-swap session hijack

- **File:** `app/controllers/accounts_controller.rb:50-73` (link_solana) + `app/controllers/omniauth_callbacks_controller.rb:11-22` + `app/models/concerns/user_mergeable.rb:6-12` (merge_users!)
- **Originating findings:** CTRL-002, CTRL-003, GEM-004
- **Exploit:** Both `link_solana` and the logged-in OAuth callback funnel collisions (`existing && existing.id != current_user.id`) into `merge_users!`, which sets `survivor = min(survivor.id, absorbed.id)` then `set_app_session(survivor)`. A fresh-account attacker (new high id) who triggers a collision with a victim (old low id) results in the merged survivor being the victim, and the session being switched into the victim. Full account takeover. For OAuth: same primitive plus `User.from_omniauth` finds-by-email without checking `email_verified`, so a Google account with a forged/unverified email matching a wallet-only Turf Monster user takes over that wallet.
- **Fix:** (a) Refuse to merge in either controller path when the other account has financial state (entries, tokens, balance, encrypted_web2_solana_private_key present). (b) Require `auth.info.email_verified == true` for OAuth-driven email lookups. (c) Make the signed wallet message embed `User-ID: <current_user.id>` and verify post-Ed25519 to bind the link to the active session.

### OPSEC-006 — MoonPay webhook fails open on missing secret

- **File:** `app/controllers/webhooks/moonpay_controller.rb:30-39`
- **Originating findings:** CTRL-005, WEBHOOK-001
- **Exploit:** `return true if webhook_key.blank?` — if `MOONPAY_WEBHOOK_KEY` is unset on Heroku (one missed env var), the webhook accepts unsigned POSTs from any internet source. Attacker forges `transaction_completed` events for arbitrary `walletAddress` and `quoteCurrencyAmount`, triggering `MoonpayDepositJob` to fund those wallets with USDC from the treasury. Combined with OPSEC-022 (no DB unique index for external payment IDs), N forged events with N distinct IDs all pass.
- **Fix:** Hard-fail in production when key blank: `return false if webhook_key.blank? && !Rails.env.development?`. Boot-time assertion in `config/initializers/moonpay.rb` raising if `MOONPAY_WEBHOOK_KEY` blank under `Rails.env.production?`.

### OPSEC-007 — `update_level` trusts client-supplied `seeds_total`

- **File:** `app/controllers/accounts_controller.rb:99-108`
- **Originating finding:** CTRL-001
- **Exploit:** `PATCH /account/update_level seeds_total=99999999` directly persists `current_user.level`. The level drives the "Free Entry Earned 🎟️" UI badge (per memory, a marketing vector). Attacker pumps level → screenshots → social-engineers operator into manual mint at `/admin/free_entries`. Even without ops engagement, the level value pollutes leaderboards and any future tier-reward logic.
- **Fix:** Delete the route. Recompute level server-side from `Solana::Vault.new.sync_balance(current_user.solana_address)[:seeds]`.

### OPSEC-008 — Stripe DEPOSIT path trusts webhook metadata for amount

- **File:** `app/services/stripe_checkout_validator.rb:87-95`, `app/controllers/webhooks/stripe_controller.rb:81-87`
- **Originating finding:** WEBHOOK-003
- **Exploit:** For `kind != "tokens"` (deposit flow), `amount_matches?` returns `true` unconditionally. The handler then uses `session.metadata["amount_cents"].to_i` to drive `StripeDepositJob`. The session's actual `amount_total` (the only authoritative paid amount) is never compared. Combined with OPSEC-006-class signature bypass or a future server bug that sets mismatched metadata, $1 paid → $500 credited. Even absent those, any path that constructs a Checkout session with attacker-influenced metadata becomes a money-printing bug.
- **Fix:** In `amount_matches?`, always compare `session.amount_total == session.metadata["amount_cents"].to_i`. Drive `StripeDepositJob` off `session.amount_total` (the authoritative figure), not metadata.

### OPSEC-009 — TokenPurchaseJob partial-mint TOCTOU on Sidekiq retry

- **File:** `app/jobs/token_purchase_job.rb:11-46`
- **Originating findings:** WEBHOOK-004, SVC-013
- **Exploit:** `for_session.exists?` returns true after the `StripePurchase` row is created at the top of the job. If `vault.mint_entry_token` succeeds for tokens 1-2 of a 3-pack and fails on 3 (RPC timeout, slot lag), the job raises. Sidekiq retries — but the early-return at line 11 sees the row exists and returns immediately. `mint_tx_signatures` is only persisted at the end of the loop, so the retry has no resume point. User paid $49 and got 1-2 tokens; no audit trail of which were minted.
- **Fix:** Persist `tx_signatures` incrementally inside the loop (per-mint save). On retry, skip mints whose `EntryTokenAccount` PDA already exists on-chain (the Anchor `init` constraint is the source of truth). Alternatively split into N single-mint jobs each with key `stripe:#{session_id}:#{i}`.

### OPSEC-010 — `verify_solana_transaction!` lacks semantic verification

- **File:** `app/controllers/contests_controller.rb:638-654` (and callers at `:83`, `:143`, `:370-407`)
- **Originating findings:** CTRL-008, SVC-005, also CTRL-009/SVC-006 for the admin variant
- **Exploit:** The verifier checks only that the TX exists and `meta.err` is nil. It does not check (a) program ID matches Turf Vault, (b) the instruction is the expected one (e.g., `enter_contest_direct`, `settle_contest`, `create_contest`), (c) the signer is `current_user.web3_solana_address`, (d) the PDAs referenced match the server-derived expected PDAs, (e) the `tx_signature` hasn't already been consumed by another DB row. Attacker submits ANY successful past TX signature (e.g., a $0.01 SOL transfer) as `tx_signature` to "confirm" their cart entry without paying. The DB flips status; the prize pool is short their entry fee.
- **Fix:** Fetch `meta.transaction.message.accountKeys` and `instructions`. Assert program ID matches `Solana::Config::PROGRAM_ID`. Decode the instruction discriminator and assert it matches the expected operation. Assert a writable account at the expected PDA position. For `confirm_onchain_entry`, re-derive `entry_pda` server-side and compare. For `pending_transactions#confirm`, assert one of the signer keys matches the claimed `cosigner_address` AND that it's in the multisig set.

### OPSEC-011 — `PendingTransactions#confirm` trusts client tx_signature for settlement

- **File:** `app/controllers/admin/pending_transactions_controller.rb:14-39`
- **Originating findings:** CTRL-009, SVC-006
- **Exploit:** Action writes `params[:tx_signature]` and `params[:cosigner_address]` straight to DB and flips `target.update!(onchain_settled: true)` for contests. No on-chain re-fetch, no instruction validation, no signer check. A rogue admin (or attacker holding admin session via OPSEC-005) flips `onchain_settled` for a $1881 large contest by POSTing any string — subsequent admin payout clicks proceed against a contest that was never actually settled on-chain.
- **Fix:** Call the same hardened `verify_solana_transaction!` from OPSEC-010. Specifically assert: settle_contest instruction, target contest PDA in accounts, cosigner pubkey appears in TX signers AND is in `MULTISIG_SIGNERS`.

### OPSEC-012 — `Solana::Config::PROGRAM_ID` fallback is the orphaned program ID

- **File:** `app/services/solana/config.rb:3`
- **Originating finding:** SVC-003
- **Exploit:** Env-fallback hardcodes `7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J`, the orphan with no upgrade authority in our possession. If `SOLANA_PROGRAM_ID` is unset/misnamed on Heroku mainnet, the app silently talks to a non-existent address — and if anyone deploys a program at that address on mainnet, we hand them our users' TXs. Adjacent risk: rake error messages at `solana.rake:373` still print the stale ID, misleading incident response.
- **Fix:** Remove the hardcoded fallback. Make `SOLANA_PROGRAM_ID` required at boot in production (raise `KeyError` if missing). Add a boot-time assertion that the value matches a sealed mainnet allowlist post-Squads-migration.

### OPSEC-013 — `force_close_vault` rake has no network guard

- **File:** `lib/tasks/solana.rake:52` (and `init_vault`, `migrate_user_account` adjacent)
- **Originating findings:** OPS-002, SVC-019
- **Exploit:** `bin/rails solana:init_vault FORCE_CLOSE=true` calls `vault.force_close_vault` with no `Solana::Config.devnet?` or `Rails.env.production?` check (other destructive tasks like faucet, mint, airdrop have this guard). A typo on a production console destroys the live vault. The on-chain 2-of-3 multisig is the only defense — and the bot signer is automatic, the human signer might cosign reflexively.
- **Fix:** `raise "force_close disabled outside devnet" if Solana::Config.mainnet?` at the top of each destructive rake task. Add `CONFIRM_PROD=yes` requirement for any prod-destructive op.

### OPSEC-014 — `EXPECTED_IDL_HASH` fails open when blank in production

- **File:** `app/services/solana/config.rb:70-90`, `config/initializers/solana_idl_verification.rb:11-18`
- **Originating findings:** OPS-004, SVC-012
- **Exploit:** `verify_idl!` returns nil silently when `EXPECTED_IDL_HASH.blank?` or `idl_hash.nil?`. Combined with `SKIP_IDL_VERIFICATION=true` escape hatch, a malicious deploy unsets both and silently boots against a drifted/tampered program. The post-audit checklist already flags this env var as still TODO — current production boots with verification disabled.
- **Fix:** In production, raise if `EXPECTED_IDL_HASH` blank OR if `IDL_PATH` missing. Require `SKIP_REASON` to be set + a Sentry alert raised when `SKIP_IDL_VERIFICATION=true`.

### OPSEC-015 — `SECRET_KEY_BASE` permanently locks managed-wallet encryption

- **File:** `app/services/solana/keypair.rb:30`
- **Originating findings:** OPS-003, SVC-002
- **Exploit:** AES key derives from `Rails.application.credentials.secret_key_base[0, 32]`. `secret_key_base` is a 128-char hex string; `[0, 32]` returns 32 hex *characters* — effective 128 bits of entropy (silent downgrade from advertised 256). Worse: no key derivation function, no version tag, no rotation path. If `RAILS_MASTER_KEY` is ever rotated, every `encrypted_web2_solana_private_key` in the DB becomes undecryptable and every managed-wallet user loses access to their funds. A routine credentials rotation becomes a wallet-destruction event.
- **Fix:** Two-step: (a) Switch to `ActiveSupport::KeyGenerator.new(secret_key_base).generate_key("turf-monster wallet encryption v1", 32)` for full 256-bit material. (b) Introduce a separate `MANAGED_WALLET_ENCRYPTION_KEY` env var that is rotation-isolated from `SECRET_KEY_BASE`, with a documented rotation procedure that re-encrypts existing rows. (c) Cold-backup `RAILS_MASTER_KEY` to paper/safe before mainnet.

### OPSEC-016 — GET `/sso_login` mutates session — CSRF + cross-app takeover via shared cookie

- **File:** `studio-engine/app/controllers/sessions_controller.rb:19`, `studio-engine/lib/studio.rb:119`
- **Originating finding:** GEM-001
- **Exploit:** GET endpoint calls `set_app_session(user)` based on `session[:sso_email]`. CSRF doesn't cover GETs; browsers prefetch GETs; `<img src=…>` triggers GETs. The `_studio_session` cookie spans `*.mcritchie.studio` — an XSS anywhere in any subdomain (current OR future satellite) can write `session[:sso_email]`, and a subsequent `/sso_login` visit from any source auto-creates the user and starts a session. `authenticate_sso_user!` auto-provisions if missing, so no prior account needed.
- **Fix:** Change route to POST-only and require CSRF token. Add `Origin`/`Referer` check binding the request to the hub domain. Better: hub mints a single-use signed token, satellite consumes it via POST with token verification.

### OPSEC-017 — `Solana::Transaction#serialize` doesn't verify signer count

- **File:** `solana-studio/lib/solana/transaction.rb:80-93`
- **Originating finding:** GEM-005
- **Exploit:** Wire header writes `num_required_signatures` based on accounts marked `is_signer: true`. If `@signers.length < num_required_signatures`, gem produces a malformed payload silently — RPC rejects, but no client-side detection. `serialize_partial` is worse: writes `"\x00" * 64` for missing slots (line 127), so a partially-signed TX missing a required signer can still be broadcast by a wrapper that doesn't merge sigs. On a vault drain operation, a caller's bug becomes a silent failure or worse a signed TX with hopefully-no-effect that wastes admin SOL.
- **Fix:** Raise in `serialize` if `@signers.length != num_required_signatures`. Same check in `serialize_partial` after counting both `@signers` and `@_additional_signers`. Assert each signer's public_key appears as `is_signer: true` in `account_keys`.

### OPSEC-018 — `Solana::AuthVerifier` has no domain binding

- **File:** `solana-studio/lib/solana/auth_verifier.rb:70`
- **Originating findings:** GEM-006, CTRL-022
- **Exploit:** Verifier only matches `Nonce: <stored_value>` in the message. Doesn't enforce the message references the host app, domain, or action. If turf-monster issues nonce `ABC123` and any third-party dApp coaxes the same user to sign a message containing the same nonce (timing/leak/social), that signature passes turf-monster login verify. Standard SIWS (Sign-In With Solana) format binds host, statement, version, chain-id, issued-at, etc. — this gem doesn't.
- **Fix:** Require `expected_host:` param to `verify!`. Assert message starts with a canonical SIWS-style prefix: `"#{host} wants you to sign in...\nDomain: #{host}\n"`. Reject otherwise.

### OPSEC-019 — Inline login is an unrate-limited password oracle

- **File:** `app/controllers/inline_sessions_controller.rb:1-16`
- **Originating findings:** CTRL-004, OPS-006
- **Exploit:** JSON endpoint, `skip_before_action :require_authentication`, no rate-limiting, no lockout, no CAPTCHA. Scripted credential-stuffing trivially. Returns user info on success — perfect enumeration target. Same root cause: no `rack-attack` anywhere in the stack.
- **Fix:** Add `rack-attack`. Throttle per-IP and per-email on `/login`, `/sessions/inline`, `/auth/solana/nonce`, `/auth/solana/verify`, `/tokens/stripe_checkout`, `/wallet/airdrop`, `/faucet`, `/webhooks/*`. Default 5/min per IP, 20/min per email.

### OPSEC-020 — Faucet / airdrop / dev_mint / add_funds gated only by `Solana::Config.devnet?`

- **File:** `app/controllers/faucet_controller.rb:12-48`, `app/controllers/wallets_controller.rb:133-162`, `app/controllers/admin_controller.rb:20-36`, `app/controllers/tokens_controller.rb:75-94`, `app/controllers/users_controller.rb:4-19`
- **Originating findings:** CTRL-006, WEBHOOK-006
- **Exploit:** All "free money" endpoints check only `Solana::Config.devnet?`, which reads `SOLANA_NETWORK` env (default `"devnet"`). One env-var slip → infinite money. `UsersController#add_funds` has NO devnet guard at all — admin-only, but combined with OPSEC-005 takeover paths, a compromised admin account drains the bot. `FaucetController#claim` per-call cap is $500 but no per-day or per-user cap.
- **Fix:** Add `raise "Disabled on mainnet" if Rails.env.production?` to every faucet/airdrop/mint/add_funds action. Disable the routes entirely behind `unless Rails.env.production?` in `config/routes.rb`. Add a `SOLANA_NETWORK == 'mainnet-beta'` boot assertion that prints which devnet-only actions are disabled.

### OPSEC-021 — Admin keypair + managed wallet keys held in process memory without inspect redaction

- **File:** `app/services/solana/keypair.rb:7-13` (class-level `@admin ||=`), `app/models/user.rb:142-145` (decrypt on every call, returned to caller)
- **Originating findings:** SVC-001, SVC-002, SVC-010
- **Exploit:** Admin `Solana::Keypair` is memoized for dyno lifetime. Managed-user keypairs are decrypted on each call and held until GC. `Solana::Keypair` has no overridden `inspect`/`to_s` — Sentry default `include_local_variables=false` is current, but flipping it to true (common debugging move) would ship the 64-byte secret offsite on any exception with a keypair-typed local. `awesome_print` is in the bundle. Heroku `ps:exec` enables debugger attach if anyone turns it on.
- **Fix:** Override `Solana::Keypair#inspect` and `#to_s` to redact (`<Keypair pubkey=#{addr[0..7]}…>`). Override `marshal_dump`. Pin Sentry `include_local_variables = false` and `before_send` scrubber that drops frame vars named `*keypair*`, `*private*`, `*secret*`. Confirm Heroku `ps:exec` is disabled in production.

### OPSEC-022 — Deposit job idempotency via JSONB scan, no DB unique index

- **File:** `app/jobs/stripe_deposit_job.rb:6`, `app/jobs/moonpay_deposit_job.rb:6`, `db/schema.rb:340-347`
- **Originating finding:** WEBHOOK-009
- **Exploit:** Both deposit jobs gate on `TransactionLog.exists?(metadata: {…_id: …})`. No unique index on `metadata` keys. Sidekiq's at-least-once delivery + concurrent workers means TOCTOU between `exists?` and `record!` — double-fund. `StripePurchase` has a unique index for token purchases, but the deposit path uses `TransactionLog` only.
- **Fix:** Add a `stripe_session_id` text column + unique partial index to `transaction_logs`. Same for `moonpay_tx_id`. Let DB UNIQUE catch the race.

---

## 3. High Findings (Fix Before Mainnet Open)

### OPSEC-023 — `Season` account is unconstrained across all four enter_contest variants

- **File:** `programs/turf_vault/src/instructions/enter_contest_direct.rs:77`, `enter_contest_direct_with_token.rs:67`, `enter_contest.rs:51`, `enter_contest_with_token.rs:65`
- **Originating finding:** VAULT-003
- **Exploit:** `season: Account<'info, Season>` has no `seeds` constraint and `Contest` doesn't store `season_id`. Caller passes any `Season`. For `enter_contest_direct` (user-permissionless per OPSEC-024), users always pick the max-seed-schedule season. Levels accumulate fast, future tier-reward features become drains.
- **Fix:** Add `contest.season_id: u32` field, set at `create_contest`. Constrain `season` with `seeds = [b"season", contest.season_id.to_le_bytes().as_ref()]`.

### OPSEC-024 — `enter_contest_direct` has no admin/signer gating

- **File:** `programs/turf_vault/src/instructions/enter_contest_direct.rs:27-31`
- **Originating finding:** VAULT-004
- **Exploit:** Unlike `enter_contest`, no `vault_state.is_signer(&payer.key())` check. Anyone can be payer. Combined with OPSEC-023, users self-serve entries with any season and any entry_num, racing to claim slot 0 (highest seed reward) before Rails allocates centrally. Funds-safe (user signs their own USDC transfer) but breaks Rails' assumption that direct-entry is operator-mediated.
- **Fix:** Either add `is_signer(&payer.key())` to gate via operator, or accept user-permissionless intentionally and make `entry_num` deterministic (derive from `contest.current_entries` at instruction time).

### OPSEC-025 — `create_contest` payout sum uses unchecked arithmetic

- **File:** `programs/turf_vault/src/instructions/create_contest.rs:57`
- **Originating finding:** VAULT-005
- **Exploit:** `payout_amounts.iter().sum::<u64>()` wraps silently. Attacker creator constructs `payout_amounts = [u64::MAX, 1]` with `prizes=0`, sum overflows to 0, equality check passes, no USDC transferred but contest stores attacker-controlled payout array. Direct on-chain settle bounds by `entry_fees + prizes` (small) so program-level theft is bounded — but if Rails reads `payout_amounts` for UI display or off-chain settlement math, attacker controls the display.
- **Fix:** `try_fold(0u64, |acc, x| acc.checked_add(*x)).ok_or(Overflow)?`.

### OPSEC-026 — `force_close_vault` is replayable indefinitely on the new vault

- **File:** `programs/turf_vault/src/instructions/force_close_vault.rs:30-73`
- **Originating finding:** VAULT-006
- **Exploit:** No version check, no `migration_complete` flag. The instruction validates 2-of-3 against bytes at offsets `data[8..104]`, which on the new vault is still the signers array. Compromised admin + phished cosigner can drain VaultState lamports and zero data at any time. Vault USDC accounts persist (PDA-owned) but become orphaned because no `vault_state` for seeds. Effective program DoS until re-init + migration of every UserAccount + every Contest.
- **Fix:** Add a one-shot `VaultState.migration_locked: bool` set true post-migration, refuse `force_close` when locked. Or check that the data layout's first 8 bytes indicate old schema before proceeding.

### OPSEC-027 — `update_signers` can lock out the multisig

- **File:** `programs/turf_vault/src/instructions/update_signers.rs:21-31`
- **Originating finding:** VAULT-011
- **Exploit:** Validates `new_threshold in 1..=3` and rejects duplicates, but doesn't require the current admin/cosigner to appear in `new_signers`. Two compromised signers rotate to three attacker addresses; legitimate parties locked out. Or a fat-finger Phantom paste during rotation bricks the multisig.
- **Fix:** `require!(new_signers.contains(&admin.key()) || new_signers.contains(&cosigner.key()))`. Better: 2-step rotation with a 7-day timelock.

### OPSEC-028 — `mint_entry_token` 1-of-3 admin authority + server-subsidized prize pool = vault drain primitive

- **File:** `programs/turf_vault/src/instructions/mint_entry_token.rs:16-48`
- **Originating finding:** VAULT-009
- **Exploit:** A compromised Alex Bot key (1-of-3) can mint unlimited `EntryTokenAccount`s to attacker wallets. Consuming each via `enter_contest_with_token` enters server-subsidized contests at zero attacker cost. Attacker majority-stuffs a 100-entry contest with 80 free entries, wins prizes ($1500 per contest per CLAUDE.md memory), repeats. Iterated: $75K/week burn until detection. Detection is off-chain (Rails monitors mint events without matching Stripe `source_ref`).
- **Fix (v2 follow-up):** Require 2-of-3 for `mint_entry_token`. Or add daily mint rate-limit PDA. Or require on-chain Stripe-session-hash commitment with 24h challenge window. As short-term mitigation: add Rails alert on any mint without a corresponding `StripePurchase` row.

### OPSEC-029 — `mint_entry_token` source_ref not validated, enables compromised-admin trail forgery

- **File:** `programs/turf_vault/src/instructions/mint_entry_token.rs:55-71`
- **Originating finding:** VAULT-010
- **Exploit:** `source: u8` accepts any value; `source_ref: [u8; 64]` is opaque. No collision check. Compromised admin mints duplicates sharing legitimate `source_ref` values — detection-evasion (the on-chain trail looks legit).
- **Fix:** Validate `source` ∈ {0,1,2}. Add a `MintLedger` PDA seeded by `(source, source_ref_hash)` with `init` to enforce one-mint-per-external-ref.

### OPSEC-030 — `payout_entry` race double-pay (and adjacent race patterns)

- **File:** `app/controllers/contests_controller.rb:162-183` (payout_entry), `app/controllers/transaction_logs_controller.rb:25-45` (approve), `app/controllers/admin/free_entries_controller.rb:13-24` (mint), `app/controllers/contests_controller.rb:229-314` (enter token-funded path)
- **Originating findings:** CTRL-007, CTRL-014, CTRL-023, CTRL-010
- **Exploit:** All four use the same read-then-act pattern with no row lock. Two concurrent admin clicks (or two admin tabs) pass the "already done?" check, both invoke the on-chain operation, last write wins on the DB column. For `payout_entry`: $1000 first-place paid twice = real $1000 loss. For `approve`: same on withdrawals. For `mint`: double-mints free tokens. For `enter` token-funded: admin SOL rent for a doomed second TX.
- **Fix:** Wrap each in `record.with_lock { ... }`. Or atomic claim: `Entry.where(id:, payout_tx_signature: nil).update_all(payout_tx_signature: 'claiming-by-' + Process.pid)` and check `affected_rows == 1`. The locking pattern needs to become a controller convention.

### OPSEC-031 — `WalletsController#withdraw` doesn't validate balance at request time

- **File:** `app/controllers/wallets_controller.rb:110-131`
- **Originating finding:** CTRL-013
- **Exploit:** `amount_dollars = params[:amount].to_f`, persisted to TransactionLog without comparing to user's on-chain USDC balance. Admin reviewing the queue may approve a withdrawal larger than the user has, and `approve` calls `vault.withdraw(txn.user.solana_keypair, amount_lamports)` directly. If the source is the bot wallet (e.g. for managed users), bot drains itself; if it's the user's ATA, TX fails on-chain.
- **Fix:** Cap at on-chain balance at request time AND re-check at approve time. Refuse to enqueue requests > balance with a clear error.

### OPSEC-032 — Stripe webhook secret not asserted at boot

- **File:** `config/initializers/stripe.rb`, `app/controllers/webhooks/stripe_controller.rb:11-21`
- **Originating finding:** WEBHOOK-002
- **Exploit:** Nil `STRIPE_WEBHOOK_SECRET` causes `Stripe::Webhook.construct_event(payload, sig, nil)` to raise `ArgumentError`. Controller only rescues `JSON::ParserError` and `Stripe::SignatureVerificationError` — ArgumentError 500s. Stripe retries 3x and gives up. Real customers pay → never get tokens → chargeback wave.
- **Fix:** In `stripe.rb`, raise in production if either `STRIPE_SECRET_KEY` or `STRIPE_WEBHOOK_SECRET` is blank. Add `Rails.application.config.x.stripe_webhook_enabled` flag. Additional defense: in production refuse to boot if `STRIPE_SECRET_KEY` doesn't start with `sk_live_`.

### OPSEC-033 — No livemode gate at controller level in webhook

- **File:** `app/controllers/webhooks/stripe_controller.rb:23-44`
- **Originating finding:** WEBHOOK-005
- **Exploit:** Livemode check exists in the validator's re-fetch path, but only runs for `checkout.session.completed`. If production env has a misconfigured `STRIPE_SECRET_KEY=sk_test_…` (the current `.env` per audit memory), test-mode events re-fetch under a test key and pass — minting real mainnet tokens for test-mode payments. The Stripe key correctness is silently load-bearing.
- **Fix:** Add controller-level gate before re-fetch: `return head :ok if Rails.env.production? && !event.livemode`. Also enforce `sk_live_` prefix at boot.

### OPSEC-034 — `dev_mint` route + admin gating brittle

- **File:** `app/controllers/tokens_controller.rb:75-94, 103-106`, `config/routes.rb:147`
- **Originating finding:** WEBHOOK-006
- **Exploit:** Gated only by `current_user&.admin? && Solana::Config.devnet?`. Any bug in the filter chain, any accidental `skip_before_action` on a child, any env-var flip leaves a free-mint endpoint exposed. No `TransactionLog` row created for dev mints — no audit trail.
- **Fix:** Route-level disable: `post "tokens/dev_mint", ... unless Rails.env.production?`. Always log dev mints to `TransactionLog` regardless of environment.

### OPSEC-035 — MoonPay amount field is wrong AND under-validated

- **File:** `app/controllers/webhooks/moonpay_controller.rb:46-48`
- **Originating finding:** WEBHOOK-008
- **Exploit:** Uses `data["quoteCurrencyAmount"]` (the *fiat* amount per MoonPay docs) where it should use `baseCurrencyAmount` (the *crypto* amount). So users get credited in USD as if it were USDC — misattribution at best, massive over-credit at worst depending on exchange rate. Also no server-side order pre-registration: nothing persists what the user agreed to buy before redirecting to MoonPay, so there's no record to validate against.
- **Fix:** Re-fetch transaction via MoonPay API `GET /v1/transactions/{id}`, use the authoritative `cryptoAmount` field. Persist a `MoonpayPurchase` order row when initiating redirect with an idempotency token; look up by id in the webhook.

### OPSEC-036 — No chargeback / dispute / refund handler

- **File:** `app/controllers/webhooks/stripe_controller.rb:25-44`
- **Originating finding:** WEBHOOK-010
- **Exploit:** Only `checkout.session.completed` handled. `charge.refunded`, `charge.dispute.created`, `charge.dispute.funds_withdrawn`, `payment_intent.payment_failed` all silently ignored. Attacker buys 3-pack with stolen card → 3 tokens mint → uses to enter contest → ~10-60 days later issuer disputes → Stripe debits $49 + $15 dispute fee. Operator eats every loss. The `refund_status` column on `StripePurchase` is dead — nothing writes to it.
- **Fix:** Handle `charge.dispute.created` → flag `users.payment_risk_flag = true`, block further token purchases, alert ops via `RECONCILER_ALERT_WEBHOOK`. Handle `charge.refunded` → mark `StripePurchase.refund_status = "refunded"`, attempt on-chain token revocation if unspent.

### OPSEC-037 — `OutboundRequestLogger` captures signed TX bytes verbatim

- **File:** `app/services/outbound_request_logger.rb:10-19`, `app/services/solana/client_logger.rb:10-37`
- **Originating finding:** SVC-008
- **Exploit:** `SENSITIVE_KEYS` whitelist is generic; doesn't redact Solana RPC payloads. Every `sendTransaction` RPC writes base64-encoded signed TX bytes to `outbound_requests` DB table. Pre-broadcast signed TXs (partially-signed admin TXs awaiting cosign) include admin signatures — replayable inside the ~2-minute blockhash window. `mint_entry_token` `source_ref` writes Stripe session ids verbatim. DB dump → adversary can correlate users, replay never-confirmed TXs, harvest payment metadata.
- **Fix:** Hash + truncate Solana RPC params for `sendTransaction`/`sendRawTransaction`/`simulateTransaction`. Add explicit redaction for the first param of these methods. Store only post-broadcast TX signature, never the signed payload.

### OPSEC-038 — `filter_parameter_logging` is incomplete

- **File:** `config/initializers/filter_parameter_logging.rb:7`
- **Originating findings:** SVC-009, OPS-007, CTRL-027, WEBHOOK-007
- **Exploit:** Filter is `[:passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn]`. `_key` catches `encrypted_web2_solana_private_key` via partial match. Missing: `:signature`, `:serialized_tx`, `:tx`, `:private_key`, `:mnemonic`, `:recovery_phrase`, `:webhook_signature`. Heroku log drain captures `params[:serialized_tx]` on admin pending-transaction endpoints, `params[:signature]` from Phantom auth, `customer_email` from Stripe webhook (via `TokensLogger.dump`, which goes to `Rails.logger` and bypasses `filter_parameters` entirely). 7-day retention on Heroku Papertrail/Logentries makes this a meaningful PII exposure.
- **Fix:** Add `:signature, :serialized_tx, :tx, :private_key, :mnemonic, :recovery_phrase, :webhook_signature, :nonce` to filter. Wrap `TokensLogger.dump` (and `Solana::ClientLogger`) in explicit field redaction. Confirm `customer_email` is stripped from `[tokens]` lines.

### OPSEC-039 — No `SOLANA_NETWORK` / `PROGRAM_ID` / `RPC_URL` cross-validation

- **File:** `app/services/solana/config.rb` (all three constants), no `verify_network_alignment!` step
- **Originating findings:** OPS-005, SVC-015
- **Exploit:** Three env vars set independently. Mainnet RPC + devnet program ID (or vice versa) boots silently. Combined with OPSEC-013 + OPSEC-020, an operator's misconfig fires devnet-destructive ops on the live program. The RPC URL itself is unvalidated; if `SOLANA_RPC_URL` is hijacked via Heroku config access (no second-factor on Heroku config writes), all signed TXs go to attacker RPC pre-broadcast — observability blind spot at minimum.
- **Fix:** Boot-time: call `getGenesisHash` on the configured RPC, compare against pinned mainnet/devnet hash. Refuse to boot on mismatch. Allowlist `SOLANA_RPC_URL` to known providers (Helius, QuickNode, Triton, Solana Foundation endpoints). Default `SOLANA_NETWORK` to `nil`, raise if missing in production.

### OPSEC-040 — Queue adapter mismatch: cron + Sidekiq jobs may never run in production

- **File:** `config/environments/production.rb:75` (`queue_adapter = :async`), `config/initializers/sidekiq_cron.rb`, `Procfile`
- **Originating finding:** OPS-009
- **Exploit:** `queue_adapter = :async` runs jobs in web dyno threads, not Sidekiq. `sidekiq_cron.rb` only loads under `Sidekiq.server?` (worker dyno). If worker isn't scaled and adapter isn't fixed, the reconciler cron (15-min interval, the only DB↔chain divergence detector) never fires. `TokenPurchaseJob` runs in web thread, potentially blocking request response.
- **Fix:** Change to `config.active_job.queue_adapter = :sidekiq` in production. Confirm worker dyno scaled ≥ 1. Verify cron jobs in `/admin/jobs` after deploy.

### OPSEC-041 — Shared `*.mcritchie.studio` cookie + cross-app session — single XSS = total takeover

- **File:** `config/initializers/session_store.rb` (per CLAUDE.md, domain `.mcritchie.studio`)
- **Originating finding:** OPS-010
- **Exploit:** Both apps share `SECRET_KEY_BASE` (required for SSO). One XSS on any subdomain (current or future satellite) reads the session cookie and acts as that user on every McRitchie app — including triggering wallet ops on turf-monster.
- **Fix:** Confirm cookie attrs (`secure: true, httponly: true, samesite: :lax`). Add Content-Security-Policy headers (currently absent). Long-term: replace the shared-cookie SSO with per-app encrypted token handoff.

### OPSEC-042 — `current_user` legacy `session[:user_id]` fallback enables cross-app fixation

- **File:** `studio-engine/app/controllers/concerns/studio/error_handling.rb:23-28`
- **Originating finding:** GEM-003
- **Exploit:** If `session[Studio.session_key]` is empty BUT `session[:user_id]` is present, the engine looks up by that ID and calls `set_app_session(user)`. Combined with shared subdomain cookie, an XSS that writes `session[:user_id]` anywhere becomes login-as-anyone everywhere. The Devise-era migration window is over.
- **Fix:** Delete the legacy-migration block. If retention required, scope it to a hub-specific controller with a signed-timestamp check.

### OPSEC-043 — `Transaction.serialize_partial` instance-variable signer state non-thread-safe

- **File:** `solana-studio/lib/solana/transaction.rb:108-133`
- **Originating finding:** GEM-002
- **Exploit:** `@_additional_signers ||= []` + `additional_signers.each { ... << pk }` — instance ivar accumulates across calls. `ensure` resets only on normal exit. If a Transaction builder is memoized or shared across requests/threads (which the turf-monster `Vault` doesn't currently do, but the API invites), two parallel partial-sign flows leak signers between transactions: wrong fee-payer, wrong message bytes signed.
- **Fix:** Refactor `serialize_partial` to accept `additional_signers` as a local arg, drop the ivar. Document `Transaction` as single-use-and-discard.

### OPSEC-044 — `solana_sessions#verify` auto-creates a user — Sybil farm via SOL drain

- **File:** `app/controllers/solana_sessions_controller.rb:15-44`, `app/models/user.rb` after_create
- **Originating finding:** CTRL-021
- **Exploit:** Any wallet that signs a nonce gets a User row. `after_create :generate_managed_wallet!` enqueues `EnsureAtaJob` — admin SOL rent per new user. Attacker scripts the loop, exhausts admin SOL.
- **Fix:** Per-IP rate-limit. Defer managed-wallet creation until first contest interaction (lazy ATA).

### OPSEC-045 — `change_password` doesn't invalidate other sessions

- **File:** `app/controllers/accounts_controller.rb:110-126`
- **Originating finding:** CTRL-015
- **Exploit:** Standard hardening miss. If attacker holds victim's session (XSS, stolen cookie), victim's password change does not boot the attacker. Money still drainable from the still-active hijacked session.
- **Fix:** Add `session_token` column, bump on password change + sensitive ops, include in session lookup.

### OPSEC-046 — Email change without re-auth or confirmation

- **File:** `app/controllers/accounts_controller.rb:130-132`
- **Originating finding:** CTRL-016
- **Exploit:** `account_params` permits `:email`. No old-address notification, no password re-prompt. Combined with OPSEC-005 OAuth merge primitive, an attacker who briefly holds a session can change email to one they control then re-take the account via Google OAuth later.
- **Fix:** Confirmation email to old address. Require current password for email changes.

### OPSEC-047 — `enter_contest_direct_with_token` similar gating gap

- **File:** `programs/turf_vault/src/instructions/enter_contest_direct_with_token.rs:14-21`
- **Originating finding:** VAULT-002 / VAULT-003 cross-cut
- **Exploit:** No `is_signer` constraint on `vault_state`. `payer` is just any signer (pays rent), `user` signs. Combined with OPSEC-023, user picks max-seed season. The on-chain instruction itself doesn't lose money but the inflated seeds drive level / future tier-reward features.
- **Fix:** Bind season per OPSEC-023; consider tying `payer = user` to disable the "admin facilitates" framing for this direct variant.

### OPSEC-048 — Settlement does not require every entry be in the settlement vec

- **File:** `programs/turf_vault/src/instructions/settle_contest.rs:36-106`
- **Originating finding:** VAULT-015
- **Exploit:** Empty or partial `settlements: Vec<Settlement>` flips status to Settled with no error. Missed entries stuck `Active` forever. `close_contest` allows close on `Settled` Contest regardless of per-entry status.
- **Fix:** `require!(settlements.len() == contest.current_entries)`.

### OPSEC-049 — `set_inviter` no rate-limit, no first-touch enforcement

- **File:** `app/controllers/accounts_controller.rb:84-97`
- **Originating finding:** CTRL-017
- **Exploit:** Sets `current_user.invited_by_id` from public slug. If referral rewards ever launch, this is the Sybil farm: create N accounts, point each at the attacker.
- **Fix:** First-touch-server-side via signed cookie set by `/r/:slug`. Reject if `current_user.created_at < 5.minutes.ago` (signup-time decision only).

### OPSEC-050 — `Admin::SeasonsController#set_current` doesn't validate on-chain existence

- **File:** `app/controllers/admin/seasons_controller.rb:11-46`
- **Originating finding:** CTRL-024
- **Exploit:** Admin typo points the live system at a non-existent season, breaking every subsequent entry. No on-chain validation.
- **Fix:** Validate season exists via `vault.list_seasons` before persisting.

---

## 4. Medium Findings (Track + Fix Within 90 Days)

| ID | File:line | Description |
|---|---|---|
| OPSEC-051 | `programs/turf_vault/src/instructions/force_close_vault.rs:22-27`, `migrate_user_account.rs:26-30` | Runtime `find_program_address` (no stored bump) is OK for canonical-bump verification but inconsistent with codebase pattern. Minor. (VAULT-007) |
| OPSEC-052 | `turf-vault/CLAUDE.md`, multiple references | Stale orphan program ID `7Hy8…r2J` everywhere — `declare_id!()` is correct (`Dx8u…GaCT`) but docs mislead incident response. (VAULT-008) |
| OPSEC-053 | `programs/turf_vault/src/instructions/initialize.rs:51` | Admin not enforced at `signers[0]` though CLAUDE.md implies. Defensive position naming nit. (VAULT-013) |
| OPSEC-054 | `programs/turf_vault/src/instructions/close_contest.rs:1-28` | Closing a Contest doesn't sweep residual vault USDC — accounting becomes inferred off-chain. (VAULT-014) |
| OPSEC-055 | `app/controllers/contests_controller.rb:483-493` | `fill` admin action hard-codes seeded test users; on mainnet wastes real USDC per click. (CTRL-018) |
| OPSEC-056 | `app/controllers/contests_controller.rb:452-532` | `simulate_game`/`jump`/`reset` admin actions live in prod routes — re-triggers payouts if invoked on settled contests. (CTRL-019) |
| OPSEC-057 | `app/controllers/webhooks/stripe_controller.rb:62-64` | Validator-rejected events return 200 OK with no Sentry capture; bug = silent loss. (CTRL-020, WEBHOOK-016) |
| OPSEC-058 | `app/services/solana/reconciler.rb:14-23` | RPC failure during `sync_balance` treated as "missing account" → mass-alert spam. (SVC-014) |
| OPSEC-059 | `app/controllers/contests_controller.rb:233-263` | Managed-wallet token consumption requires only session auth (no wallet signature) — session hijack burns paid tokens. (SVC-016) |
| OPSEC-060 | `lib/tasks/solana.rake:100-106` | `generate_keypair` puts encrypted-key output to stdout (Heroku log drain). Use stderr + tty? gate. (SVC-018) |
| OPSEC-061 | `app/controllers/webhooks/moonpay_controller.rb:50-53` | User attribution by `walletAddress` is spoofable. Tie to server-side order record. (WEBHOOK-011) |
| OPSEC-062 | `app/services/stripe_checkout_validator.rb:75-78` | Only rescues `Stripe::InvalidRequestError`; transient `APIConnectionError`/`AuthenticationError` 500s with no retry. (WEBHOOK-012) |
| OPSEC-063 | `app/controllers/wallets_controller.rb:47` | Stripe deposit amount bounds enforced only at request time, not webhook time. (WEBHOOK-013) |
| OPSEC-064 | `app/controllers/tokens_controller.rb:23-49` | Promotion codes not explicitly disabled. Future regression risk. (WEBHOOK-015) |
| OPSEC-065 | `studio-engine/lib/studio/s3.rb:19-21,44-48` | `s3_bucket_prefix` interpolation no char validation. Misconfig → bad-host URLs. (GEM-007) |
| OPSEC-066 | `studio-engine/app/models/error_log.rb:21,33-41` | `ErrorLog.capture!` fans to Sentry without scrubbing `exception.message`. Document or wrap. (GEM-008) |
| OPSEC-067 | `solana-studio/lib/solana/keypair.rb:29-32` | `Keypair.from_json_file(path)` does plain `File.read` — document trust-source-only, optionally Pathname-guard. (GEM-009) |
| OPSEC-068 | `studio-engine/docs/GOOGLE_AUTH_SETUP.md:50` | Docs recommend `OmniAuth.config.allowed_request_methods = [:post, :get]`. GET defeats CSRF protection. Should be `[:post]`. (GEM-012) |
| OPSEC-069 | `solana-studio/lib/solana/spl_token.rb:61-77` | Uses legacy `Transfer` (discriminator 3) not `TransferChecked` (12). Add `transfer_checked_instruction` builder. (GEM-018) |
| OPSEC-070 | `solana-studio/lib/solana/client.rb:61-79` | `send_and_confirm` poll with no exp-backoff; under RPC rate-limit, false timeout error. (GEM-011) |
| OPSEC-071 | `Gemfile` + CI | No `bundler-audit` in CI. Adds free CVE coverage. (OPS-Q2) |
| OPSEC-072 | RPC provider | `SOLANA_RPC_URL` defaults to public devnet endpoint — rate-limited under real load. Mainnet needs paid provider. (OPS-Q6) |

---

## 5. Low Findings + Nits

- **OPSEC-073** — `Sentry.init` does not pin `include_local_variables = false` explicitly (default is false in current SDK, but worth pinning + adding a `before_send` scrubber). [`config/initializers/sentry.rb`, SVC-024]
- **OPSEC-074** — `Solana::Client` send-transaction retry behavior is opaque; verify it doesn't re-broadcast with a fresh blockhash (would enable double-submit). [SVC-025]
- **OPSEC-075** — `Solana::Config::MULTISIG_SIGNERS` hardcodes production signer pubkeys in source. Not secret but rotation = redeploy. [`app/services/solana/config.rb:15-17`, SVC-023]
- **OPSEC-076** — `Solana::Config::ADMIN_KEYPAIR_PATH` is dead config. Remove. [`config.rb:12`, SVC-011]
- **OPSEC-077** — `StripePurchase.name_slug` includes 16 chars of session_id in URL slug. Use random hex. [`app/models/stripe_purchase.rb:48-50`, WEBHOOK-018]
- **OPSEC-078** — `Stripe.api_key = ENV["..."]` happens at boot with no production nil-check beyond a warning. (Closely related to OPSEC-032.) [`config/initializers/stripe.rb`, WEBHOOK-019]
- **OPSEC-079** — `StripePurchase.refund_status` column exists but is dead code (no writes). Misleading. [WEBHOOK-021]
- **OPSEC-080** — `Vault.mint_entry_token` `source_ref` stores full Stripe session ID on-chain. Use truncated HMAC. [`app/jobs/token_purchase_job.rb:42`, WEBHOOK-024]
- **OPSEC-081** — `AuthVerifier.verify!` error messages leak input byte-length, useful for fingerprinting. Reduce to generic. [`solana-studio/lib/solana/auth_verifier.rb:61,64`, GEM-013]
- **OPSEC-082** — `display_balance` swallows all errors → "$0". UX-misleading. [`app/controllers/application_controller.rb:50-66`, CTRL-026]
- **OPSEC-083** — `Solana::Config::PROGRAM_ID` literal is stale (orphan) for runtime fallback. Cross-references OPSEC-012 but documented separately as a cosmetic+latent risk. [SVC-003, OPS-013]
- **OPSEC-084** — `tokens/processing?session_id=…` echoes session ID via Alpine view; confirm template escapes. [WEBHOOK-014]
- **OPSEC-085** — `wallet#show?deposit=success` URL flag should not drive any state assertion in views. [`app/controllers/wallets_controller.rb`, CTRL-012]
- **OPSEC-086** — `create_user_account` allows anyone to pay rent for someone else's PDA — admin spending griefing surface (negligible). [VAULT-019]
- **OPSEC-087** — `migrate_user_account` writes wallet from data into struct via raw bytes; PDA constraint already enforces match. Defensive nit. [VAULT-007 detail]
- **OPSEC-088** — `Studio.welcome_message` flash interpolation — confirm `_flash.html.erb` Alpine handler uses `x-text` not `x-html`. [GEM-010]
- **OPSEC-089** — `ErrorLog` show view shows full backtrace + DB primary keys; if `admin?` is ever subdivided into "viewer admin", revisit. [GEM-014]

---

## 6. Production Readiness Checklist

Tracking against the Squads migration runbook, house-burn-down protocols, and audit findings above.

### Pre-mainnet hard prerequisites

- [x] **OPSEC-002** Squads upgrade-authority migration executed (devnet rehearsal first, then mainnet)
- [ ] **OPSEC-025 (#25 ecosystem-audit Tier 3)** External Anchor audit engaged and completed (Halborn / Neodyme / OtterSec / Zellic)
- [x] **OPSEC-001** `WalletsController#deposit` deleted or production-disabled
- [x] **OPSEC-003** `settle_contest` dedup fix shipped
- [x] **OPSEC-004** `enter_contest_with_token` requires user signer
- [x] **OPSEC-005** Account merge primitives refuse collisions on financial-state accounts; OAuth requires `email_verified == true`
- [x] **OPSEC-006** MoonPay webhook fail-closed when key blank; boot-time assertion
- [x] **OPSEC-007** `update_level` route deleted, level recomputed server-side
- [x] **OPSEC-008** Stripe DEPOSIT path validates `amount_total == metadata.amount_cents`
- [x] **OPSEC-009** TokenPurchaseJob per-mint incremental signature persistence; resume from on-chain state
- [x] **OPSEC-010** `verify_solana_transaction!` validates program + instruction + signer + PDA
- [x] **OPSEC-011** `PendingTransactions#confirm` uses the hardened verifier
- [x] **OPSEC-012** `SOLANA_PROGRAM_ID` required at boot; orphan fallback removed
- [x] **OPSEC-013** `force_close_vault`, `init_vault`, `migrate_user_account` rake tasks gated on `Rails.env.production?` + `CONFIRM_PROD=yes`
- [x] **OPSEC-014** `EXPECTED_IDL_HASH` required in production; fail-closed
- [x] **OPSEC-015** Managed-wallet KDF switched to `KeyGenerator` with documented `MANAGED_WALLET_ENCRYPTION_KEY` rotation path; `RAILS_MASTER_KEY` in cold storage
- [x] **OPSEC-016** `/sso_login` POST-only + CSRF token
- [x] **OPSEC-017** `Transaction#serialize` raises on signer count mismatch
- [x] **OPSEC-018** `AuthVerifier.verify!` enforces canonical host-bound message prefix
- [x] **OPSEC-019** `rack-attack` installed with throttles on auth/webhook/payment endpoints
- [x] **OPSEC-020** Faucet/airdrop/mint/add_funds endpoints production-disabled at route + controller level
- [x] **OPSEC-021** `Solana::Keypair#inspect/to_s` redacted; Sentry `include_local_variables = false` pinned + scrubber
- [x] **OPSEC-022** DB unique index on `transaction_logs(stripe_session_id)` and `transaction_logs(moonpay_tx_id)`
- [x] **OPSEC-036** Stripe `charge.dispute.created` + `charge.refunded` handlers wired
- [x] **OPSEC-040** `queue_adapter = :sidekiq` in production + worker dyno scaled
- [x] **OPSEC-041** CSP headers added; session cookie attrs verified `secure: true, httponly: true, samesite: :lax`
- [x] **OPSEC-042** Legacy `session[:user_id]` migration block deleted

### Heroku env vars to set (per `audit-post-execution-checklist`)

- [ ] `SOLANA_PROGRAM_ID` (mainnet program ID, post-Squads-migration)
- [ ] `SOLANA_NETWORK=mainnet-beta`
- [ ] `SOLANA_RPC_URL` (paid provider)
- [ ] `EXPECTED_IDL_HASH` (post-`bin/rails solana:idl_hash`)
- [ ] `SENTRY_DSN`
- [ ] `RECONCILER_ALERT_WEBHOOK`
- [ ] `STRIPE_SECRET_KEY` (live, `sk_live_` prefix)
- [ ] `STRIPE_WEBHOOK_SECRET` (live)
- [ ] `MOONPAY_WEBHOOK_KEY` (live)
- [ ] `MOONPAY_API_KEY`, `MOONPAY_SECRET_KEY` (live)

### Should-have before launch (HIGH-severity items)

- [x] OPSEC-023 Season binding (`contest.season_id` + PDA seeds)
- [x] OPSEC-024 `enter_contest_direct` gating decision (admin-gated OR deterministic entry_num)
- [x] OPSEC-025 `create_contest` payout sum `checked_add`
- [x] OPSEC-026 `force_close_vault` migration lock
- [x] OPSEC-027 `update_signers` lockout protection
- [ ] OPSEC-028 `mint_entry_token` short-term mitigation (Rails alert on mint-without-purchase)
- [x] OPSEC-030 Row-locking convention across all admin money-handling actions
- [x] OPSEC-031 Withdraw balance validation
- [x] OPSEC-032 Stripe webhook secret boot assertion + `sk_live_` prefix check
- [x] OPSEC-033 Controller-level livemode gate
- [x] OPSEC-035 MoonPay credits crypto amount only (fiat-fallback bug fixed); authoritative API re-fetch deferred — pre-mainnet
- [x] OPSEC-037 OutboundRequestLogger redact Solana RPC params
- [x] OPSEC-038 Filter `:signature, :serialized_tx, :private_key, :mnemonic, :recovery_phrase`
- [x] OPSEC-039 `getGenesisHash` cross-validation at boot
- [x] OPSEC-043 `Transaction.serialize_partial` ivar refactor
- [x] OPSEC-044 Defer `EnsureAtaJob` until first contest interaction
- [x] OPSEC-045 Session invalidation on password change

### Operational backlog (post-launch tracking)

- [ ] OPSEC-051 through OPSEC-089 — track via the GitHub issue label `opsec-medium` / `opsec-low`
- [ ] Stranded-contest recovery runbook (OPS-W5)
- [ ] DB restore drill on schedule (OPS-W2)
- [ ] Heroku collaborator review (OPS-W1)
- [ ] Sidekiq concurrency tuning + queue-depth alarm (OPS-W6)
- [ ] HSTS preload + custom domain TLS verified (OPS-W7)
- [ ] Solana::Client circuit breaker (OPS-W4)

---

## 7. Recommended Fix Priority Order

Three rough waves. **Wave 1** unblocks the next mainnet planning conversation. **Wave 2** is what ships before a single real-money user touches the system. **Wave 3** is concurrent with Wave 2 but on independent long-lead timelines.

### Wave 1 — Ship This Week (~2-3 days of focused work)

These are the highest-impact, lowest-effort fixes. They should land before continuing any other launch-prep work.

1. **OPSEC-001** Delete `WalletsController#deposit`. One-line guard or full removal. **<30 min.**
2. **OPSEC-007** Delete `update_level` route + recompute server-side. **30 min.**
3. **OPSEC-006** MoonPay webhook fail-closed + boot assertion. **45 min.**
4. **OPSEC-013** Add `Rails.env.production?` guards to all destructive rake tasks. **30 min.**
5. **OPSEC-020** Production-disable faucet/airdrop/mint/add_funds routes. **45 min.**
6. **OPSEC-012** Remove orphan-program-ID fallback; require env var at boot. **30 min.**
7. **OPSEC-014** Require `EXPECTED_IDL_HASH` in production. **15 min.**
8. **OPSEC-038** Expand `filter_parameter_logging`. **15 min.**
9. **OPSEC-021** Override `Solana::Keypair#inspect` and `#to_s`. **30 min.**
10. **OPSEC-040** Switch production queue adapter to `:sidekiq`; confirm worker. **30 min + ops check.**
11. **OPSEC-042** Delete legacy `session[:user_id]` migration. **15 min.**
12. **OPSEC-044** Lazy `EnsureAtaJob` deferral. **1-2 hr.**

Wave 1 covers `~12` critical findings with cumulative effort under one workday for a focused operator.

### Wave 2 — Ship Before Mainnet Open (~2-3 weeks)

Engineering work that requires careful design + testing. Parallelizable across the four layers.

**Anchor (turf-vault), in a single audited release:**
- OPSEC-003 `settle_contest` dedup
- OPSEC-004 `enter_contest_with_token` user signer requirement
- OPSEC-023 + OPSEC-047 Season binding
- OPSEC-024 `enter_contest_direct` signer decision
- OPSEC-025 `create_contest` checked sum
- OPSEC-026 `force_close_vault` migration lock
- OPSEC-027 `update_signers` lockout protection
- OPSEC-029 `mint_entry_token` source_ref validation + MintLedger PDA
- OPSEC-048 Settlement completeness require

**Rails controllers:**
- OPSEC-005 Account merge primitive hardening (link_solana + OAuth)
- OPSEC-010 `verify_solana_transaction!` semantic verification
- OPSEC-011 `PendingTransactions#confirm` using hardened verifier
- OPSEC-019 `rack-attack` installed
- OPSEC-030 Row-locking convention applied across `payout_entry`, `approve`, `free_entries#mint`, token-funded `enter`
- OPSEC-031 Withdraw balance validation
- OPSEC-032 Stripe webhook secret boot assertion + `sk_live_` check
- OPSEC-033 Controller-level livemode gate
- OPSEC-034 `dev_mint` route-level disable
- OPSEC-045, OPSEC-046 Session/email change hardening

**Webhooks / payments:**
- OPSEC-008 Stripe deposit metadata validation
- OPSEC-009 TokenPurchaseJob incremental persistence
- OPSEC-022 DB unique indexes on external payment IDs
- OPSEC-035 MoonPay authoritative re-fetch
- OPSEC-036 Chargeback / dispute / refund handlers

**Gems:**
- OPSEC-016 `/sso_login` POST + CSRF
- OPSEC-017 `Transaction#serialize` signer count check
- OPSEC-018 `AuthVerifier` host binding
- OPSEC-043 `Transaction#serialize_partial` ivar refactor

**Ops + config:**
- OPSEC-015 KDF + rotation path for managed wallet encryption
- OPSEC-037 `OutboundRequestLogger` Solana RPC redaction
- OPSEC-039 `getGenesisHash` cross-validation
- OPSEC-041 CSP headers + cookie attr verification
- Heroku env var checklist (SENTRY_DSN, RECONCILER_ALERT_WEBHOOK, IDL hash, all payment provider keys)

### Wave 3 — Concurrent Long-Lead Items

- **OPSEC-002** Squads upgrade-authority migration. Execute the runbook on devnet → mainnet. ~3-5 days execution + cosign coordination.
- **OPSEC-025-equivalent (ecosystem-audit Tier 3 #19)** External Anchor audit. **Send the RFP today.** Lead time 4-8 weeks + $20-60k. Don't wait on Wave 2 to engage; engage now and ship Wave 2 fixes into the audit window for re-audit pass.
- **OPSEC-028 (v2 follow-up)** 2-of-3 multisig for `mint_entry_token` + daily rate-limit PDA. ~1 week. Stretches into post-launch but should land before token volume scales.

### Mainnet launch gates (per Squads runbook §Step 4)

The Squads runbook already specifies the phased rollout (smoke → capped → uncapped). Adopt unchanged. Adjust caps based on this audit's residual risk:

- **Phase A (smoke):** Internal only. ≤ $50 total at risk. Audit findings Wave 1+2 shipped. Squads migrated.
- **Phase B (capped):** Real users. Per-contest TVL cap $500. Daily mint cap (e.g., 100 tokens). Audit complete + re-audit pass. Reconciler webhook posting to ops chat.
- **Phase C (uncapped):** Lift caps after 50 successful settlement cycles with zero divergence and zero chargeback exceeding 1%.

---

## 8. Post-Audit Additions (Incident-Driven)

> Findings discovered after the 2026-05-19 audit, appended to keep a single canonical OPSEC tracker. Numbering continues from OPSEC-089. Each entry records the triggering incident.

### OPSEC-090 — Non-prod process can transact on mainnet when all Solana env vars are *consistently* mainnet (no "is this prod?" guard)

- **Severity:** HIGH (real-money loss vector; the triggering incident was recoverable, the class is not always)
- **File:** `turf-monster/app/services/solana/config.rb` (cluster / mint / program / network selection — `NETWORK`, `mainnet?`, `USDC_MINT`, `PROGRAM_ID`), `turf-monster/app/services/solana/vault.rb` (all tx builders + broadcast: `build_create_contest`, `build_enter_contest`, `cosign_and_broadcast_entry`, `mint_entry_token`, `create_contest_server_funded`, and the private `build_tx` / `build_partial_signed` / `build_partial_unsigned` / `build_tx_unsigned` chokepoints). Adjacent to the OPSEC-039 boot guard at `turf-monster/config/initializers/solana_network_alignment.rb`.
- **Originating incident:** 2026-06-13. Alex ran a contest-entry/create flow from the **local** turf-monster dev app (`localhost:3100`) while Phantom was pointed at mainnet. At that moment the local app was *also* fully configured for mainnet — `SOLANA_PROGRAM_ID=DaFv…` (live mainnet program), mainnet Helius RPC, mainnet USDC mint `EPjFW…`, and the mainnet admin/payer key `8K81`. A real `CreateContest` executed on mainnet and moved **45 real USDC** into a mainnet prize pool. Recovered separately via `cancel_contest`.
- **Why existing guards missed it:** The OPSEC-039 genesis-alignment guard (`solana_network_alignment.rb`) only blocks *mixed* clusters — e.g. a mainnet program ID with a devnet RPC. Here all three vars were *consistently* mainnet, so `getGenesisHash` matched the declared `mainnet-beta` and the check passed. OPSEC-039 validates **internal consistency**, not **"a dev/local process has any business touching mainnet at all."** That second question was never asked. This is the pattern-#10 ("Devnet-only-via-config, no defense in depth") failure mode inverted: there is no `Rails.env`-layered gate forcing non-prod processes off mainnet.
- **Exploit / blast radius:** Any developer (or agent) whose local `.env` points at the live cluster — a stale `.env`, a copy-pasted prod config var, a worktree that inherited the wrong `SOLANA_*` set — can sign and broadcast real-money instructions (`create_contest`, `enter_contest`, `mint_entry_token`, settlement cosigns) against the live program with the live admin key, from a laptop, with zero confirmation prompt. The funds move is silent and indistinguishable from prod traffic in the outbound-request log.
- **Requested guard:** In **non-production** environments (anything where `Rails.env.production?` is false — local/dev/test, i.e. not the prod Heroku dyno), the app must **HARD-REFUSE** to (a) boot and (b) build or submit any transaction when the resolved cluster is `mainnet-beta`, **UNLESS** an explicit opt-in `ALLOW_LOCAL_MAINNET=true` is set. Default = block. Mirror the OPSEC-039 escape-hatch ergonomics (`SOLANA_SKIP_NETWORK_CHECK`) so the bypass is deliberate, env-var-gated, and loud in logs when active.
- **Recommended approach (do NOT implement yet — ticket only):**
  1. **Single predicate on `Solana::Config`** — add `Solana::Config.local_mainnet_blocked?` (true when `!Rails.env.production? && mainnet? && ENV["ALLOW_LOCAL_MAINNET"] != "true"`) plus a `raise_if_local_mainnet!(context)` helper that builds the loud error message. Centralizing the decision in `Config` keeps the boot guard and the runtime guard in lockstep — same rule, one source of truth (avoids the OPSEC-075-class "logic duplicated, drifts" smell).
  2. **Defense in depth — two enforcement points:**
     - **Boot-time initializer** (sibling to `solana_network_alignment.rb`, e.g. `config/initializers/solana_local_mainnet_guard.rb`) — fail the process at startup, mirroring OPSEC-039. This catches the common case (dev server / console / Sidekiq booting against a mainnet `.env`) before any traffic. Run inside `config.after_initialize` so `Solana::Config` is loaded, same as OPSEC-039.
     - **Runtime guard at the tx chokepoint** — call `Solana::Config.raise_if_local_mainnet!` from the lowest common transaction-build/broadcast helpers in `vault.rb` (the private `build_tx*` / `build_partial_*` methods, and/or `cosign_and_broadcast_entry`). This closes the gap where a long-running dev process started on devnet and the operator swapped `.env` to mainnet mid-session without restarting (Sidekiq snapshots `.env` at boot — see the `bin/tm restart` note in turf-monster CLAUDE.md), and it defends against any future code path that bypasses the boot guard.
  3. **"Is prod?" detection** — `Rails.env.production?` is the reliable, already-load-bearing signal: the prod Heroku dynos run `RAILS_ENV=production`; local/dev/test never do. Do **not** infer "prod" from the presence of mainnet env vars (that's the exact thing this guard exists to catch — circular). Prefer this over a `DYNO`/hostname sniff.
  4. **Test environment** — enforce in test too (the incident scope is "not the prod dyno"), but expect that any test deliberately exercising mainnet config must set `ALLOW_LOCAL_MAINNET=true`, exactly as OPSEC-039 tests set `SOLANA_SKIP_NETWORK_CHECK`. Default test `NETWORK` is `devnet`, so the common path is unaffected.
  5. **Error message — loud and prescriptive:** name the offending var set, the resolved cluster, and the one-line opt-in. e.g.:
     ```
     Refusing to run a non-production process against MAINNET (OPSEC-090).

       RAILS_ENV         = development
       SOLANA_NETWORK    = mainnet-beta
       SOLANA_PROGRAM_ID = DaFv…
       SOLANA_USDC_MINT  = EPjFW… (real USDC)

     A dev/test process is about to sign real-money instructions with the live admin key.
     This is almost certainly a stale or copy-pasted .env.
     To proceed anyway (you are SURE you want local→mainnet): ALLOW_LOCAL_MAINNET=true
     ```
- **Verification (post-fix):** (a) `RAILS_ENV=development SOLANA_NETWORK=mainnet-beta bin/rails runner 'true'` must raise at boot; (b) the same with `ALLOW_LOCAL_MAINNET=true` must boot and log the bypass loudly; (c) a unit test asserting `Solana::Config.local_mainnet_blocked?` truth table across the `Rails.env` × `NETWORK` × `ALLOW_LOCAL_MAINNET` matrix; (d) a vault test asserting `build_create_contest` (or the shared `build_tx` helper) raises under dev+mainnet-no-optin. Cross-reference OPSEC-039 (consistency check) and OPSEC-013/OPSEC-020 (the `Rails.env.production?`-layered destructive-op gates this generalizes).

---

## Patterns Worth Naming

These cross-cut the findings and should drive code review going forward.

1. **Trusted-client state.** Anywhere the server accepts a `tx_signature`, `seeds_total`, `amount`, `entry_pda`, `cosigner_address`, `wallet_address`, or any other on-chain identifier from the client without independent re-derivation is a money-loss bug waiting to happen. The `params_token` HMAC pattern in Phantom contest creation is the right model — extend it everywhere.
2. **Server-as-signer concentration risk.** The admin keypair is the single most valuable secret in the stack. It signs vault ops AND signs as every managed-wallet user. RCE on any dyno or laptop with the env var = total compromise. Squads migration removes the upgrade vector; this audit doesn't fully remove the transactional vector (a compromised admin can still drain via OPSEC-003-class settlement bugs even with Squads).
3. **Fail-open defaults.** Multiple "if env var blank, skip the check" patterns (IDL pin, MoonPay sig verify, devnet detection). Each is a single missing env var away from disabling a security control. Default behavior should fail closed in production; failure should be loud at boot, not silent on every request.
4. **DB↔chain divergence + read-then-act races.** The reconciler exists, but the upstream code keeps creating divergence faster than it can be detected. Row-locking conventions on every money-handling controller action would eliminate most of these.
5. **Account merge primitives.** Any path that auto-merges users on collision becomes a hijack primitive when the merge function performs ID-swap. Refuse to merge accounts with financial state; require explicit confirmation flows.
6. **Missing rate limits everywhere.** Login, wallet auth, signup, faucet, Stripe checkout, webhook endpoints — all unprotected. `rack-attack` is a one-day investment that closes a wide attack surface.
7. **Log leakage.** Three places leak: `outbound_requests` table (signed TX bytes), Rails log drain (filter_parameter_logging gaps + bypassing via `Rails.logger.info`), Sentry (no `before_send` scrubber, unfiltered exception messages). Sensitive data should never reach any of them.
8. **Network/env split-brain.** `SOLANA_NETWORK`, `SOLANA_PROGRAM_ID`, `SOLANA_RPC_URL` are independent env vars. Any mismatch = silent misroute. Boot-time `getGenesisHash` validation collapses this.
9. **Mainnet-prereqs documented but undone.** Squads migration, external audit, Sentry DSN, reconciler webhook, IDL hash pin — all documented as mainnet-blockers, none yet done in production. The audit + Squads is the long-lead critical path.
10. **Devnet-only-via-config (no defense in depth).** Faucet, airdrop, dev_mint, force_close, fill, add_funds — all gated by `Solana::Config.devnet?` or admin gating, never both layered with `Rails.env.production?`. One config slip = real money.

---

## What's Not in Scope, but Worth Naming

- **DDoS / rate-limiting at CDN / Heroku layer.** Out of code scope; should be tracked separately.
- **KYC / AML / tax reporting.** Operator + legal scope.
- **Mainnet RPC provider selection.** Decision deferred until launch budget is firm.
- **Front-end XSS hardening.** Touched at the cookie-scope level (OPSEC-041) but a full XSS audit of Alpine templates and view helpers is its own engagement.
- **Tokenomics review.** $19 entry / $1500 prize pool subsidies are an operator-acknowledged v1 gap. Tracked in memory as an intentional decision.

---

## Acknowledgments

This audit was performed via six parallel investigation agents spanning the Anchor program, Rails controllers, Rails service layer, webhooks/payments, shared gems, and operational envelope. Each agent had ~1500 words of output; this document consolidates and dedupes. Total raw findings ≈ 140; consolidated unique findings = 89 (OPSEC-001 through OPSEC-089). Post-audit incident-driven findings are appended in § 8 (OPSEC-090+) and continue the numbering.

**Re-audit cadence:** Re-run quarterly or whenever a new payment processor / new on-chain instruction / new auth method ships. The current audit reflects the state of the code on **2026-05-19**.

**Next document expected after audit:** A separate session triages findings into PR-sized work items and sequences them against the Squads migration + external audit timeline. Do not start fixing from this document directly — triage first.
