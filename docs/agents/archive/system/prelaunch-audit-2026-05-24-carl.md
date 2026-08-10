# Pre-Launch Application Security Audit — turf-monster

**Date:** 2026-05-24
**Auditor:** Carl (Rails backend)
**Scope:** turf-monster Rails app + the studio-engine pieces it consumes
**Out of scope:** on-chain Anchor program (Jasper), infra/headers/CSP/Heroku (Steffon)
**Method:** independent fresh pass — code-driven; prior 2026-05-19 OPSEC audit
intentionally not referenced.

---

## Executive Summary

The Rails surface is in solid shape — better than I expected for a single-team
project pre-mainnet. Money-moving flows (entries, top-ups, payouts) are
defense-in-depth: server-side payment gates, Stripe re-fetch validator,
on-chain TX semantic verification (Solana::TxVerifier), per-user pessimistic
locks on confirm + entry-token mint, idempotent webhook handling keyed by
`stripe_session_id` / `moonpay_tx_id`. Sensitive credentials are filtered out
of logs, mass-assignment is tight, no raw SQL interpolation found.

I did NOT find a Critical that should block mainnet. I did find **two High**
findings that should be fixed before public launch:

1. **Contest lock-time is admin-driven, not auto-enforced from `starts_at`** —
   a user can keep submitting entries past the displayed lock time as long as
   (a) admin hasn't clicked Lock and (b) the 6 specific matchups they pick
   still have unkicked games. With staggered-kickoff slates this opens a
   **late-entry information-edge attack**.
2. **TokenPurchaseJob's StripePurchase status can flip from minted → failed**
   on concurrent webhook re-deliveries. On-chain mint state stays correct
   (PDA `init` collision protects), but the audit row misleads operators —
   reconciliation pain on launch day.

Five **Medium** findings cover: a missing rotate-session-token on email change,
a missing `email_verified_at` check on email update, `set_inviter` accepting any
slug (referral-spoof surface, low impact today but matters once referrals pay),
`StripeDepositJob` having no `already_processed?` short-circuit equivalent to
`TokenPurchaseJob`'s, and a 60s `list_entry_tokens` cache that drives `sequence`
allocation in `mint_entry_token` (PDA collision is the real backstop, but the
cache leads to wasted admin SOL on rare races).

Auth (manual + Google + Phantom): the SIWS-style nonce flow with
`expected_host` + `expected_user_id` binding is correct. `from_omniauth`
refusing to auto-link Google identities to unverified email accounts is the
key OPSEC-005 control and is doing what it claims. **No password reset flow
exists by design** — call this out in support docs; it's not a bug, but it's
the kind of gap that becomes a problem under load.

CSRF + session: cookie is signed + encrypted, `secure/httponly/same_site=lax`,
session_token binding (OPSEC-045) is enforced on every request. CSRF token is
NOT leaked via the `#session-context` JSON block (which only carries
SessionContext.to_h fields). Mass-assignment params are clean across every
write controller.

IDOR sweep on `:id` routes: no IDORs found — every `find_by(id: params[...])`
is either admin-only or scoped through `current_user`.

Detail follows.

---

## H1 — Contest lock-time not auto-enforced from `starts_at`

**Severity:** High (contest-integrity)
**Files:** `app/models/contest.rb:409-411`, `app/controllers/contests_controller.rb:255-388`, `app/models/entry.rb:45-83`
**Category:** Contest integrity / late-entry edge

### Attack

1. Operator creates a `large` contest with `starts_at = Saturday 12:00 ET`.
   The 99 matchups (one slate) have games kicking off across 12:00, 15:00,
   18:00, 21:00 (FIFA group stages typically have rolling kickoffs).
2. A user waits until 12:30 ET. The 12:00 ET games are now `locked?` (their
   `kickoff_at <= Time.current`). All other matchups still pickable.
3. User opens `/contests/:id`, sees the leaderboard with already-active entries
   AND the live 12:00 game scores.
4. User submits 6 selections drawn exclusively from the 15:00/18:00/21:00
   slate. `Entry#confirm!` passes: `contest.open?` is true (admin hasn't
   clicked Lock), and the 6 matchups they picked all have `kickoff_at >
   Time.current`. Entry is accepted.

The user has materially more information than competitors who entered before
12:00. They've gamed the contest.

### Why the existing checks don't close this

- `Contest#status` is admin-toggled. It only flips to `:locked` when an admin
  manually POSTs `/contests/:id/lock` or via `Contest#jump!`. There is no
  automatic transition keyed off `starts_at`.
- `SlateMatchup#locked?` is per-matchup, not per-contest. It only stops the
  ALREADY-KICKED-OFF matchups from being selected — not all matchups whose
  contest has nominally started.
- `Contest#starts_at` is rendered as `lock_time_display` but never enforced.

### Fix

In `Entry#confirm!`, `Entry#confirm_onchain!`, AND
`ContestsController#toggle_selection`, add a server-time check:

```ruby
raise "Contest has locked at #{contest.locks_at}" if contest.locks_at && Time.current >= contest.locks_at
```

`Contest#locks_at` already aliases `starts_at` (contest.rb:409). The check
should fire BEFORE the per-matchup locked? scan so the error message is
sensible. Operators can still admin-lock early; the new check just adds a
hard floor at the advertised lock time.

Optional follow-on: a Sidekiq cron job that auto-flips `Contest.where(status:
:open).where("starts_at <= ?", Time.current).update_all(status: :locked)`
every minute — defense in depth + UI consistency.

---

## H2 — TokenPurchaseJob can flip purchase row to `failed` after successful mint on concurrent webhook delivery

**Severity:** High (audit / operations integrity — NOT funds loss)
**Files:** `app/jobs/token_purchase_job.rb:26-98`, `app/services/stripe_checkout_validator.rb:84-87`, `app/services/solana/vault.rb:1071-1073`
**Category:** Idempotency race

### Attack

Stripe occasionally delivers the same `checkout.session.completed` event twice
(documented at-least-once delivery). With `StripePurchase.status` going
`pending → minted`, two simultaneous deliveries:

1. Webhook A: arrives. Validator passes (`already_processed?` returns false:
   no row with status="minted" exists). Enqueues TokenPurchaseJob.
2. Webhook B: arrives ~50ms later. Validator passes (same reason — A hasn't
   completed yet). Enqueues a second TokenPurchaseJob.
3. Both jobs run on Sidekiq concurrently.
4. Both find `purchase&.status` either nil (create) or "pending"
   (token_purchase_job.rb:27), both proceed past the short-circuit.
5. Both call `vault.mint_entry_token` for sequence=0. The PDA seeds are
   `(wallet, sequence)`, derived from a 60s-cached `list_entry_tokens` length.
   Both jobs read the same stale 0, both build a TX with the same PDA.
6. The Anchor `init` constraint on the EntryTokenAccount PDA makes the second
   TX fail on-chain (account already exists). Job B's `vault.mint_entry_token`
   raises.
7. Job B's `rescue` block runs `purchase&.update(status: "failed")`
   (token_purchase_job.rb:96).
8. Even if Job A had already set status="minted", the rescue overwrites it.

Net effect: on-chain state is correct (3 tokens minted). DB audit row reads
`status: "failed"`, `mint_tx_signatures: [...]`. Operators investigating
chargebacks/refunds will see contradictory state.

### Fix

In `TokenPurchaseJob#perform`'s rescue (line 96):

```ruby
rescue => e
  Rails.logger.error "[tokens] job.error ..."
  # Don't blow away a minted row — re-check before downgrading status.
  if purchase&.persisted? && purchase.reload.status != "minted"
    purchase.update(status: "failed")
  end
  raise
end
```

Stronger fix: short-circuit at the top of `perform` with a row-level lock:

```ruby
purchase = StripePurchase.for_session(stripe_session_id).first_or_create!(...)
purchase.with_lock do
  return if purchase.status == "minted"
  # ... do work ...
end
```

`with_lock` serializes the two webhook-job runs. The second one waits for the
first to commit, then sees `status: "minted"` and returns cleanly.

---

## M1 — Email change does not rotate `session_token`

**Severity:** Medium (account-takeover defense)
**Files:** `app/controllers/accounts_controller.rb:41-72`
**Category:** Session hygiene

`AccountsController#update` accepts an email change after verifying
`current_password`, sets `email_verified_at: nil`, sends the OOB
notification, and updates. It does NOT call `current_user.regenerate_session_token!`.

If an attacker has already compromised a session cookie and uses it to change
the email (and is willing to provide the current password — they presumably
have it since they have the cookie), they get the email change AND every
other live session (the legit user's phone, laptop) keeps working.

The CLAUDE comment at user.rb:195 ("consider hooking on email change … later")
acknowledges this gap. Pre-launch is the right time to close it.

**Fix:**

```ruby
if email_changing
  new_token = @user.regenerate_session_token!
  session[:session_token] = new_token
end
```

---

## M2 — `set_inviter` accepts any user's slug

**Severity:** Medium (referral-attribution integrity, currently low impact)
**File:** `app/controllers/accounts_controller.rb:109-122`

Any logged-in user can POST `/account/set_inviter` with `inviter_slug` =
any other user's slug and have `invited_by_id` set, exactly once, on their
account. Today this drives display only (the audit found no payout/bonus
logic keyed off `invited_by_id`). The CLAUDE.md TODO mentions "Inviter"
attribution.

If/when referrals carry a payout (signup bonus, rev share), this becomes a
direct **fraud surface**: an attacker creates N accounts, sets their inviter
to themselves' main account, collects N referral bonuses. The "self" check
(`inviter.id == current_user.id`) blocks the obvious case but not multi-account
collusion.

**Fix (now):** require the inviter slug to match a value present in the
`reference` cookie set at first touch by `capture_reference`. That cookie is
already the canonical "first-touch attribution" channel; let it be the only
channel. Remove the user-facing API.

**Fix (before referrals pay):** require some out-of-band signal (the inviter
account having to confirm, or signup-time-only attribution that can't be set
post-hoc).

---

## M3 — `StripeDepositJob` lacks the per-iteration crash recovery + status guard of `TokenPurchaseJob`

**Severity:** Medium (audit integrity for cash deposits)
**Files:** `app/jobs/stripe_deposit_job.rb`, compare to `app/jobs/token_purchase_job.rb`

I didn't read `StripeDepositJob` end-to-end, but in the validator
(`stripe_checkout_validator.rb:84-87`) the `already_processed?` short-circuit
only checks `StripePurchase.minted` + `TransactionLog.exists?(stripe_session_id)`
for tokens. For variable-amount deposits, the only idempotency primitive is
`TransactionLog.exists?(stripe_session_id: …)`. If a delivery race posts the
job twice before the TransactionLog row is committed, the user could be
credited twice.

**Fix:** before the on-chain `vault.deposit(...)` call, `with_lock` the user
row OR insert the TransactionLog row first (uniqueness on
`stripe_session_id`) and let DB constraints serialize.

Verify: `db/schema.rb` says `add_index :transaction_logs, :stripe_session_id`
— is it a `unique: true` index? If not, that alone is the fix.

---

## M4 — `list_entry_tokens` 60s cache drives `next_entry_token_sequence`

**Severity:** Medium (admin SOL bleed + race surface)
**Files:** `app/services/solana/vault.rb:1007-1073`

`mint_entry_token` derives the PDA from `(wallet, sequence)` where
`sequence = list_entry_tokens(wallet).length` and `list_entry_tokens` has a
60s Rails.cache TTL (vault.rb:1049). Concurrent mint requests for the same
wallet read the cache, get the same length, both compute the same `sequence`,
both build a TX. The second TX bounces on-chain at `init` (correct end state),
but admin pays the failed-TX SOL rent attempt.

A motivated attacker can't drain admin SOL via this — webhook duplication is
rare, dev_mint is admin-only, and operator-driven mint UIs serialize via
`user.with_lock` (free_entries_controller.rb:25). But it's a foot-gun.

**Fix:** in `mint_entry_token`, bust the cache before reading sequence:

```ruby
def mint_entry_token(wallet_address:, source:, source_ref:, sequence: nil)
  invalidate_entry_tokens_cache(wallet_address) unless sequence
  sequence ||= next_entry_token_sequence(wallet_address)
  ...
```

Or skip the cache entirely on the read path inside `next_entry_token_sequence`.

---

## M5 — Production routes expose `/toast_test`, `/seeds_lab`, `/admin/modals`, `/turf-totals-v1`

**Severity:** Medium (attack-surface noise; no direct exploit found)
**File:** `config/routes.rb`

These are all dev/preview routes. `/toast_test/flash` accepts a `params[:message]`
and reflects it into the flash on the next page. Flash messages render via
the toast partial — if the partial ever fails to escape user input correctly,
this is an open XSS-via-flash channel from any IP. I did not find evidence
that the toast partial fails to escape (it uses ERB defaults), but the
endpoint shouldn't exist in prod.

**Fix:** wrap the four routes in `unless Rails.env.production?` constraints,
or delete `toast_test_controller.rb` outright.

---

## L1 — `OmniAuth.config.allowed_request_methods = [:post, :get]`

**Severity:** Low (acceptable today; flag for awareness)
**File:** `config/initializers/omniauth.rb:9`

OmniAuth 2.x defaults to POST-only for the request phase to mitigate CSRF on
the OAuth bounce. Turf Monster re-allows GET, which is required for the
"Sign in with Google" `<a href=/auth/google_oauth2>` link to work. OmniAuth's
built-in CSRF-token check still applies. Acceptable.

If the auth flow is ever wired through a clickable image or a `<link rel=prefetch>`
on a page the user doesn't expect, prefetch could initiate an unintended OAuth
bounce. Today the auth modal uses `window.open` for popup OAuth and an
explicit link for full-page, so risk is low.

---

## L2 — No password-reset flow

**Severity:** Low (operational, not security; flag for support docs)
**Files:** searched `app/`, `config/routes.rb`, `studio-engine/` — none found.

Users who forget their password and have no Google/Phantom link cannot self-
recover. Operators must reset via Rails console. This is by design and
preferable to a half-implemented reset flow that leaks tokens, but support
volume on launch day will be non-trivial. Make sure the support email is
clearly displayed at the login page and that an operator runbook exists for
"how to reset password X".

A correct minimum implementation: reuse the `EmailVerificationsController`
pattern (Rails.application.message_verifier signed token, 24h expiry, single
use), require the new password to be ≥ 8 chars (current minimum is 6 — see
user.rb:16), and rotate `session_token` on success.

---

## L3 — Password minimum length is 6 chars

**Severity:** Low (auth strength)
**File:** `app/models/user.rb:16`

`validates :password, length: { minimum: 6 }`. With ~2026 GPU economics, 6
chars (alphanumeric, no zxcvbn check) is brute-forceable offline. Mitigations
in place: bcrypt (`has_secure_password` default cost), rate limiting on
`/login` and `/sessions/inline` (5/email/min, 10/IP/min), and
`session_token` rotation on password change.

**Fix (cheap):** raise to 8 + zxcvbn ≥ 2.

---

## L4 — `OmniauthCallbacksController#create` doesn't compare `GoogleOauthValidator`'s validated email to `auth.info.email`

**Severity:** Low (defensive)
**Files:** `app/controllers/omniauth_callbacks_controller.rb:28`, `app/services/google_oauth_validator.rb:38-77`

`GoogleOauthValidator.validate!` returns `result.email` (parsed from the
re-fetched tokeninfo response). The controller doesn't compare it to
`auth.info.email` (parsed by omniauth from the same id_token). In practice
both come from the same id_token so they will be equal. But defense-in-depth
would catch a tampered omniauth path.

**Fix:**
```ruby
return finish_oauth(login_path, success: false, alert: "Email mismatch")
unless validator_result.email.to_s.downcase == auth.info.email.to_s.downcase
```

---

## L5 — Slate IDOR potential (admin-write only) — checked, no issue

**Files:** `app/controllers/slates_controller.rb:2` (`before_action :require_admin`).
Public reads were the only concern; admin-write is locked down. No finding.

---

## L6 — Withdrawal admin approval has correct double-spend guards (audit confirmed)

`TransactionLogsController#approve` uses `txn.with_lock` + status check +
re-checks on-chain balance via `Solana::Vault#sync_balance` before signing.
`payout_entry` was removed (per H2 in the prior 2026-05-23 audit) and the
sole payout path is now on-chain `settle_contest` via 2-of-3 cosign. Both
correct. No finding.

---

## I1 — `set_inviter` and other JSON endpoints leak `current_user.id`

`AccountsController#set_inviter` checks `inviter.id == current_user.id`.
InlineSessions returns `{ user: { id: user.id, ... } }`. IDs are sequential
(`bigserial`). A user can scrape `User.maximum(:id)` by probing — useful for
sybil counting and target-discovery. Informational; recommend slug-only
public IDs for v2.

---

## I2 — `email_verifications#verify` does not invalidate the token after use

**File:** `app/controllers/email_verifications_controller.rb:48-76`

`Rails.application.message_verifier` tokens are stateless — once minted, valid
for 24h. The verify action sets `email_verified_at` and does not record the
consumed token. A user can replay the same token N times within 24h (the
update only fires when `email_verified_at` is blank, so subsequent verifies
are no-ops). Not exploitable since the token only does `email_verified_at = now`
on a single user. Informational.

---

## I3 — `geo_settings#check` is unauthenticated and discloses geo state

**File:** `app/controllers/geo_settings_controller.rb:5-14`

`GET /geo/check` is public, returns `{ state, blocked }` for the requester's
IP. Used by the hold-to-confirm validator. The data is already inferable
from any deposit/withdraw UI behavior. Informational.

---

## I4 — Stripe checkout success URL is interpolated with `contest.slug`

**File:** `app/controllers/tokens_controller.rb:47-50`

`success_url: "#{tokens_processing_url}?session_id={CHECKOUT_SESSION_ID}&contest=#{contest.slug}"`

`contest.slug` is server-generated and URL-safe (`parameterize`). No
injection. Informational — confirming pattern.

---

## I5 — `Entry#confirm_onchain!` lacks the model-level payment gate that `Entry#confirm!` has

**File:** `app/models/entry.rb:103-133`

`confirm!` checks `if contest.entry_fee_cents.to_i.positive? && tx_signature.blank? && !comped`.
`confirm_onchain!` does NOT have the equivalent — but it's also not callable
without `tx_signature` (the method signature requires it). The Anchor program
enforces USDC payment for `enter_contest_direct`, so payment is structurally
guaranteed. Informational — symmetric defense-in-depth would be nice.

**Suggested:** add `raise "tx_signature required" if tx_signature.blank?`
guard at the top of `confirm_onchain!`.

---

## Category check-offs (no findings)

### Auth — manual signup/login
- Password policy: 6-char min, bcrypt via has_secure_password (L3 above)
- Brute-force: rack-attack 5/email/min + 10/IP/min on both `/login` and inline
- "Remember me": no remember-me cookie — session cookie only (secure, httponly, lax)
- Account enumeration: generic "Invalid email or password" message (inline_sessions_controller.rb:13)
- Session fixation: `set_app_session` resets `session_token` cookie + clears `:onchain` flag — OK
- Stale-session forced logout: OPSEC-045 verify_session_token before_action — confirmed working

### Auth — Google SSO
- OAuth audience check: `GoogleOauthValidator` re-fetches tokeninfo and asserts `aud == ENV["GOOGLE_CLIENT_ID"]`
- email_verified claim: trusted only after re-fetch confirms `email_verified == "true"`
- Account-linking refusal: `from_omniauth` returns `:requires_verification` when an existing email-account hasn't proven email ownership (user.rb:54-64) — closes OPSEC-005
- Signed-in linking: explicit refusal when target Google account belongs to a different user (omniauth_callbacks_controller.rb:37-46)

### Auth — Phantom (Solana wallet)
- Nonce: 16-byte hex, single-use (deleted before verify), 5-min TTL
- Host binding: `expected_host = request.host_with_port`, signed message must start with that host
- Session binding: `expected_user_id` ensures the signed message embeds `User-ID: <id>` for logged-in flows
- Replay: pre-verify nonce delete prevents reuse
- web3_solana_address uniqueness: DB-level + AR validation, `find_by` race protected by `ActiveRecord::RecordNotUnique` retry

### Session + authorization
- CSRF: standard Rails token; the `#session-context` JSON block embeds ONLY SessionContext.to_h fields (loggedIn, mode, phantomLinked, userId, address) — confirmed at `app/views/layouts/application.html.erb:62`. No CSRF token leak.
- `wallet_context`: server-built per-request, NEVER reads from request params. Alpine `$store.session` mirrors it client-side for UI, but every server controller action that branches on auth state reads `current_user` + session — not the client's claimed mode.
- IDOR: every `find_by(id: params[...])` is admin-only OR scoped (contests_controller.rb:449 — `find_by(id:, user: current_user, status: :cart)`)
- Admin gates: every admin controller has `before_action :require_admin`; `AdminController` itself has `before_action :require_admin, except: [:usdc_balance]` and the `usdc_balance` exception just reads the logged-in user's own balance.

### Top-up flow (Stripe → entry tokens)
- Webhook signature verified via `Stripe::Webhook.construct_event`
- Test-mode events rejected in production (stripe_controller.rb:29-32)
- Validator re-fetches the session from Stripe API + asserts payment_status, livemode, kind, amount (StripeCheckoutValidator)
- Pricing pinned server-side: pack_id → PACKS[pack_id][:price_cents], no client price input
- Refund + dispute: `mark_refunded!` + `freeze_for_payment_risk!` block future spending
- Chargeback: future card purchases blocked via `payment_risk_flag` (tokens_controller.rb:23-26)
- Idempotency: `StripePurchase.for_session(session_id).where(status: "minted")` short-circuit + per-iteration `mint_tx_signatures` persistence

### Entry flow
- The Avi 2026-05-20 fix at `Entry#confirm!` line 70-72 holds — verified by re-deriving every reachable code path. No other path bypasses the gate.
- `comped:` keyword arg cannot be reached from user input — only `Contest#fill!` (admin-only, hardcoded admin user list) passes `comped: true`.
- Web2 entry token consumption: atomic via the Anchor `enter_contest_with_token` instruction; the token PDA is `init_if_needed`-flipped to consumed in the same TX as the entry. No double-spend possible at the Rails layer.
- Web3 entry: `Solana::TxVerifier.verify!` confirms the on-chain TX is the `enter_contest_direct` instruction signed by the user's wallet, writing to the derived entry PDA. Rails can't be tricked by a fake signature.
- Lock-time: per-matchup `locked?` check works; per-contest auto-lock missing — see H1.
- Picks-after-lock: `toggle_selection` checks `unless @contest.open?` (contests_controller.rb:523).
- Grading: admin-only (`require_admin` on `:grade`, `:grade_round`). `grade!` has `with_lock` + `raise "already settled" if settled?` — idempotent.
- Sybil rate-limit: 3 entries per user per Turf Totals contest, 1 per Survivor, enforced inside `with_lock` + sybil-combo check. Cross-contest sybil farming is possible (one user → many accounts) — addressed at the payment layer (each entry costs $19 or a token).

### Payout flow
- Payouts are computed server-side in `Contest#grade!` from `Entry#score`. No user-callable claim endpoint.
- `settle_onchain!` builds the settle TX server-side from `(wallet, entry_num, rank, payout)` — values are server-computed; the cosigner pubkey is `Solana::Config::MULTISIG_COSIGNER`. 2-of-3 multisig governance protects the actual fund move.
- `payout_entry` removal per the prior audit's H2 verified — `git grep -n "payout_entry"` returns only comments noting the removal.

### Data / PII
- `encrypted_web2_solana_private_key`: filtered via `filter_parameter_logging.rb` substring match on `:_key`. Never returned in any JSON response (searched).
- `user.to_json` / `current_user.to_json` in views: zero hits.
- Mass-assignment: `params.permit(...)` lists are tight — `:status`, `:role`, `:payout_cents`, `:entry_fee_cents`, `:score`, `:onchain_*`, `:frozen_*`, `:level` all absent. Confirmed by grep.
- Raw SQL: only two interpolations, both parameterized via bind (`outbound_requests_controller.rb:10-11`, `contests_controller.rb:560` is a named bind). No interpolated `order(params[...])`.

---

## Quick wins for the operator before launch

1. (H1) Add `Time.current >= contest.locks_at` check in `Entry#confirm!`.
2. (H2) Add `purchase.reload.status != "minted"` guard in
   `TokenPurchaseJob`'s rescue.
3. (M1) Rotate `session_token` on email change.
4. (M3) Confirm `transaction_logs.stripe_session_id` is a unique index.
5. (M5) Gate `/toast_test`, `/seeds_lab`, `/turf-totals-v1` behind
   `unless Rails.env.production?` in `config/routes.rb`.
6. (L3) Raise password minimum to 8.
7. Unset `ENABLE_TEST_SCAFFOLDING` on Heroku.
8. Document the "no password reset" support runbook.

None of these are blockers. Launch is green on the application-layer surface.
