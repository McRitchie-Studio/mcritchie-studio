# Pre-Launch Infra/OPSEC Audit - Steffon - 2026-05-24

Independent infrastructure pass on turf-monster (mainnet candidate) plus its blast-radius neighbors (mcritchie-studio SSO hub, studio-engine/solana-studio gems, turf-vault deploy chain). Anchor program logic (Jasper) and Rails authorization/business logic (Carl) are out of scope here.

## Verdict

Block launch. Two Critical findings, four High. The Stripe/Solana boot guards are good; the mainnet runbook is detailed; rack-attack covers the obvious credential-stuffing surface. But the SSO hub cookie is unhardened on the very domain it shares with the money app, `config.hosts` is unset on both apps (DNS rebinding to webhook endpoints), Sentry is undeployed (no production error visibility on day 1), and CSP is `unsafe-inline` + `unsafe-eval` on a real-money wallet UI. Fix C1-C2, H1-H4 before any `git push heroku main` against mainnet config.

---

## Critical

### C1 - SSO hub session cookie has no secure/httponly/same_site flags, undermining turf-monster's hardening
- File: /Users/alex/projects/mcritchie-studio/config/initializers/session_store.rb (entire file, 4 lines)
- Compare: /Users/alex/projects/turf-monster/config/initializers/session_store.rb:12-17 correctly sets all three.
- Mechanics: Both apps share `domain: .mcritchie.studio` and the same cookie name `_studio_session`. Each request from a user that touches `app.mcritchie.studio` (the hub) issues a `Set-Cookie: _studio_session=...; Path=/; Domain=.mcritchie.studio` with NO Secure, NO HttpOnly, NO SameSite. That re-writes the hardened cookie the turf-monster response set on the prior request. The browser sends the same cookie to `turf.mcritchie.studio` afterward.
- Attack: (a) Wallet-app XSS now reads the SSO cookie via `document.cookie`. (b) Any *.mcritchie.studio subdomain that gets a TLS termination misconfig (or a future http-only marketing subdomain) leaks the cookie in cleartext. (c) Cross-site CSRF defenses degrade to "depends on browser default" - Chrome's default SameSite=Lax mitigates somewhat, Firefox 102+ is similar, but Safari/older browsers vary. None of this should be left to the client.
- Fix: copy the turf-monster file verbatim into mcritchie-studio. Bump studio-engine `Studio::ErrorHandling` docs to make this a hard NEW_APP_SETUP requirement. Studio engine's RUNBOOK.md:55 and NEW_APP_SETUP.md:106-109 already promise "identical session_store.rb config" - the hub is the outlier.
- Tier: pre-launch, before mainnet credentials reach Heroku config.

### C2 - config.hosts is unset in production on both apps -> DNS-rebinding + Host-header attacks on webhook + admin endpoints
- File: /Users/alex/projects/turf-monster/config/environments/production.rb:109-115 (commented out)
- File: /Users/alex/projects/mcritchie-studio/config/environments/production.rb:98-104 (commented out)
- Attack: Rails 7 ships `ActionDispatch::HostAuthorization`, but with `config.hosts` empty the production default is to accept ANY Host header. (a) An attacker hosts evil.com that rebinds to Heroku's IP at TLS-terminator level via CNAME/TXT trickery and serves XSS-bait that the browser delivers under turf.mcritchie.studio's cookie scope. (b) Webhook hardening (/webhooks/stripe, /webhooks/moonpay) does not protect against forged Host headers - a Stripe-signed payload replayed against the dyno's direct *.herokuapp.com URL bypasses any reverse-proxy / CDN allowlist you might add later. (c) The Sidekiq admin panel under /admin/jobs is mounted in routes.rb and gated by SidekiqAdminMiddleware (session lookup); a SSRF inside the dyno hitting localhost:PORT/admin/jobs with a forged Host has unobstructed access to the Rack stack.
- Fix:
  ```
  # turf-monster production.rb
  config.hosts = [
    "turf.mcritchie.studio",
    "turf-monster.herokuapp.com",   # Heroku health checks
  ]
  config.host_authorization = { exclude: ->(req) { req.path == "/up" } }
  ```
  Same pattern for mcritchie-studio: app.mcritchie.studio + Heroku internal host.
- Tier: pre-launch.

---

## High

### H1 - Sentry is uninstalled in production (SENTRY_DSN not set), no observability on day 1
- File: /Users/alex/projects/turf-monster/config/initializers/sentry.rb:15 - `if ENV["SENTRY_DSN"].present?` guards the entire init. MAINNET_LAUNCH.md does not list SENTRY_DSN in the step-6 env-var block (lines 148-162).
- Attack scenario isn't an attack - it's blindness. First real-money exception (managed-wallet decrypt failure, Stripe webhook 500, Solana RPC timeout cascade) lives only in Heroku's ring-buffer logs (1500 lines, dropped on dyno restart). No alerting on 5xx spikes, no error grouping, no release tagging. The OPSEC-019 throttle-hit `Rails.logger.warn` lines vanish with the dyno. `ErrorLog.capture!` writes to Postgres but has no notification path.
- Fix: create Sentry project, add SENTRY_DSN to the MAINNET_LAUNCH.md step-6 block (currently missing) and to Heroku config. Also add a Heroku log drain to a retained backend (Papertrail/Logtail/Datadog) - Heroku's stock log buffer is unusable for forensics.
- Tier: pre-launch.

### H2 - CSP is unsafe-inline + unsafe-eval on script-src; one stored-XSS bug = wallet drain
- File: /Users/alex/projects/turf-monster/config/initializers/content_security_policy.rb:23
- Why it matters here: this is a Phantom wallet UI. XSS that injects a script can replace `window.solana` or `Alpine.store('session')` and silently sign attacker-crafted transactions when the user next confirms a contest entry, or it can read session_token-bound cookies and replay them (only httponly blocks doc.cookie reads - and from C1, the SSO-side cookie isn't httponly anyway).
- Mitigations already in place: `frame-ancestors :none` (clickjacking), `form-action` allow-list, `object-src :none`, the OPSEC-021 keypair #inspect redaction. Good but secondary.
- The note in the file ("v1 keeps unsafe-inline; nonce refactor in a follow-up") is a known-deferred. For real money this needs to become real - script-src `:strict_dynamic` + nonces; move the inline `selectionBoard()` / `solanaWalletConnect()` / `solanaModal` blobs (called out in turf-monster CLAUDE.md) into module form by hoisting the Alpine `x-data` factory into `Alpine.data(name, fn)` registrations on `alpine:init`, which doesn't need inline.
- Fix tier: ideally pre-launch; at minimum, add CSP violation reporting now (`policy.report_uri "/csp/report"` + a Rack endpoint or Sentry report-to-uri) so you can measure where inlines actually live before the nonce refactor. Also remove `:unsafe_eval` - nothing in the importmap modules or Alpine 3 needs it; verify by setting it to report-only in staging and watching for violations.

### H3 - Rate-limit gaps on money + identity endpoints
- File: /Users/alex/projects/turf-monster/config/initializers/rack_attack.rb
- Missing throttles for routes that take real money or move on-chain state:
  - POST /wallet/withdraw - no throttle (covered by on-chain $100/24h cap, but a flood still burns SOL fees + RPC quota)
  - POST /wallet/stripe_deposit and POST /wallet/moonpay_deposit - separate routes from /tokens/stripe_checkout (which IS throttled); a bored attacker can spam these for the same fee-bleed effect
  - POST /contests/:id/prepare_entry and POST /contests/:id/confirm_onchain_entry - Phantom entry build/confirm. Spammable from a single IP to fingerprint RPC behavior
  - POST /account/update_username and POST /account/confirm_username - username squatting / on-chain UserAccount churn (H3 follow-up flagged in MAINNET_LAUNCH.md line 263)
  - POST /account/change_password - credential rotation flood, no throttle
  - POST /registrations (engine signup) - only the inline modal variant is throttled (/registrations/inline); regular browser signup is not
  - POST /sso_continue - session mutation on the SSO hub side; no rack-attack at all on mcritchie-studio (the gem is in turf-monster only - see H4)
- Attack: any of the above lets an attacker burn admin SOL, drive up RPC bills (paid Helius endpoint per MAINNET_LAUNCH.md step 0), or do username-grab races without cost.
- Fix: add throttles. Pattern from existing init makes this 30 LOC.
- Tier: pre-launch for wallet/withdraw + deposit + entry. Username + change_password can be week-1 follow-up.

### H4 - mcritchie-studio has no rack-attack at all, and it's the SSO hub
- File: /Users/alex/projects/mcritchie-studio/Gemfile - rack-attack absent.
- Attack: brute force /login on the hub all day. Once you have hub creds, the cookie spans .mcritchie.studio (C1) and grants /sso_continue access on every satellite. The hub login endpoint is functionally a back door to turf-monster's accounts. Per studio-engine/sessions_controller.rb:7-16, hub login is plain email+password - no MFA, no captcha, no per-email throttle. Combine with C1's unhardened cookie and the SSO satellite hardening is moot.
- Fix: add `gem "rack-attack"` to mcritchie-studio's Gemfile, port the turf-monster init (drop the Solana / Stripe / faucet blocks), at minimum throttle /login IP + email and /sso_continue IP + email.
- Tier: pre-launch.

---

## Medium

### M1 - Stripe webhook idempotency keyed on session_id, not event.id
- File: /Users/alex/projects/turf-monster/app/controllers/webhooks/stripe_controller.rb:13-32, validator at /Users/alex/projects/turf-monster/app/services/stripe_checkout_validator.rb:28-29
- The validator's `already_processed?` checks for a minted StripePurchase per session. Stripe sends checkout.session.completed exactly-once for a given session, but charge.refunded / charge.dispute.* can be redelivered on retry (Stripe retries up to 3 days). The dispute handler at lines 112-122 isn't idempotent - a redelivered dispute will freeze a user a second time (no-op effectively, but logs a duplicate payment_risk_flag: true write).
- Attack: not really an attack - operational hygiene. But it means duplicate webhook deliveries can produce duplicate audit lines, making post-incident reconciliation harder.
- Fix: add a WebhookEvent table keyed on event.id, insert with find_or_create_by! before dispatch.

### M2 - Stripe construct_event uses default tolerance (300s), no explicit value
- File: /Users/alex/projects/turf-monster/app/controllers/webhooks/stripe_controller.rb:14
- 5 minutes is the documented default; fine. Flagging only because explicit-is-better - set tolerance: 300 so the next person reading the line knows.

### M3 - MoonPay webhook trusts payload (re-fetch is a "FIXME before mainnet")
- File: /Users/alex/projects/turf-monster/app/controllers/webhooks/moonpay_controller.rb:60-72
- Comment explicitly says "FIXME before mainnet: re-fetch via the MoonPay API and treat that response as authoritative instead of trusting the webhook payload." Signature is verified, idempotency on moonpay_tx_id, and the OPSEC-035 over-credit class of bug is fixed by ignoring quoteCurrencyAmount. But: a compromised MoonPay key (separate trust domain) could mint a forged signed webhook claiming any baseCurrencyAmount for any wallet address.
- Fix: do the validator pattern from Stripe - re-fetch via GET /v1/transactions/:id with a stored MoonPay API key, compare. Marked as a known TODO; ensure it's done before MOONPAY_ENABLED=true in prod.
- Tier: pre-mainnet if MoonPay is enabled; otherwise can defer behind a flag.

### M4 - BYPASS_IDL_CHECK env var is an emergency override with no audit trail
- File: /Users/alex/projects/turf-monster/app/services/solana/config.rb:97-100
- Sister escape hatch to the (removed) SKIP_IDL_VERIFICATION. Logs a single WARN on boot but no Sentry/error-log breadcrumb (Sentry not configured per H1). A compromised Heroku API token still gives an attacker a one-config-set bypass to ship an unverified IDL.
- Fix: when BYPASS_IDL_CHECK=true is read, call ErrorLog.capture! (or Sentry once H1 is fixed) with severity=warn so the bypass shows up in the persistent log channel, not just dyno stdout. Better: gate behind a 1-hour wall-clock TTL where the env var must include a timestamp.
- Tier: pre-launch nice-to-have, post-launch acceptable.

### M5 - Squads multisig signers all controlled by operator (known v1 risk)
- File: /Users/alex/projects/turf-monster/app/services/solana/config.rb:25-31 plus MAINNET_LAUNCH.md step 0 / step 2
- Alex Bot, Alex (Phantom), Mason - all three keys currently in operator's 1Password vault. The 2-of-3 threshold is meaningless until the third key (Mason or a new escrow) lives in a separately-controlled trust domain. MAINNET_LAUNCH.md line 259 "C3 - Mason's mainnet key to genuinely separate custody" acknowledges this.
- Attack: full operator-laptop compromise = upgrade authority. Vault pause won't save you because the same multisig can re-deploy a malicious program.
- Fix: physically separate Mason's key (different hardware wallet, separate 1Password account, ideally a different person's device). Document the recovery process if the off-device signer is unavailable for emergency pause.
- Tier: pre-mainnet C3 ticket is the right home; do not defer past week 1.

### M6 - Git-history secret scan was not completed (tooling blocked)
- The `git log -S` sweeps for sk_live_, BEGIN PRIVATE KEY, and MANAGED_WALLET_ENCRYPTION_KEY= returned permission errors in this sandbox. .gitignore correctly excludes .env, .env*, and config/master.key. No .env is currently tracked.
- Action required by operator: run locally
  ```
  git -C /Users/alex/projects/turf-monster log -p -S 'sk_live_' --all
  git -C /Users/alex/projects/turf-monster log -p -S 'BEGIN PRIVATE KEY' --all
  git -C /Users/alex/projects/turf-monster log -p -S 'MANAGED_WALLET_ENCRYPTION_KEY=' --all
  git -C /Users/alex/projects/turf-monster log -p -S 'helius' --all   # paid RPC URLs
  git -C /Users/alex/projects/turf-monster log -p -S 'whsec_' --all
  ```
  Then run the same against mcritchie-studio, studio-engine, solana-studio, turf-vault. Until this completes, M6 stays open.
- Tier: pre-launch.

### M7 - config.filter_parameters covers Solana/payment fields but not Stripe webhook body / OAuth state / RPC payload
- File: /Users/alex/projects/turf-monster/config/initializers/filter_parameter_logging.rb
- Coverage is good for the obvious Solana fields. But:
  - Stripe webhook bodies hit `[tokens] webhook.event_payload` dump (stripe_controller.rb:38-49) which logs customer_email as a plain field, plus full metadata. customer_email is not in filter_parameters (only the substring :email is, but the validator's `Rails.logger.info "validator.ok ..."` lines don't pass through parameter_filter - they're direct string interpolation).
  - OAuth state / code query params are not filtered. Google's state is HMAC-protected by omniauth so leak is low-impact, but the code is one-time-use; logging it makes incident forensics tied to "did the attacker have access to the log line in the 30s before exchange".
  - The Solana RPC outbound logger sanitizes per Solana::ClientLogger; verify it strips signed-tx bytes (already mentioned in OPSEC-038 comment).
- Fix: add :customer_email, :code, :state, :id_token, :access_token to the filter list. Audit the `[tokens] webhook.event_payload` dump call - only log opaque IDs, never PII fields.

### M8 - Subdomain takeover risk: no SPF/DKIM/DMARC verification of turfmonster.media documented
- Memory note project_resend_transactional_email.md says "turfmonster.media verified, sends from alex@turfmonster.media - working as of 2026-05-20". MAINNET_LAUNCH.md does not include a step to verify DNS records for the launch domain (turf.mcritchie.studio) - only Heroku DNS aliasing.
- Attack: if either mcritchie.studio or turfmonster.media has dangling CNAMEs (e.g. a removed Heroku app that still points at *.herokudns.com, or a Resend mailbox that was disabled but DNS records remain), an attacker can claim the subdomain and serve content under a trusted name, harvest emails via mis-typed addresses, etc.
- Fix: run `dig +short` over the known subdomain list (app., turf., www., api., mail., the Resend _dmarc. and _domainkey. records) and confirm every CNAME resolves to a live resource you control. Document the canonical subdomain inventory in the credentials doc.

### M9 - Pre-commit secret-scan not installed
- No .husky/, no active .git/hooks/pre-commit (only .sample files), no .pre-commit-config.yaml, no gitleaks config. CLAUDE.md mentions a pre-commit hook that runs bin/rails test but nothing greps for secrets.
- Attack: a careless dev paste of STRIPE_SECRET_KEY=sk_live_... into a commit message or a test fixture goes through. --no-verify bypass is moot when the hook doesn't exist.
- Fix: install gitleaks as a pre-commit hook (or git-secrets for AWS keys specifically). Sample config: detect sk_(live|test)_[A-Za-z0-9]{24,}, whsec_[A-Za-z0-9]{32,}, [1-9A-HJ-NP-Za-km-z]{43,44} (base58 keypair length), and the literal pattern of a managed-wallet hex key.
- Tier: pre-launch.

---

## Low

### L1 - Stripe webhook 100/min throttle is per-IP; Stripe rotates source IPs
- File: /Users/alex/projects/turf-monster/config/initializers/rack_attack.rb:66-68
- Real Stripe deliveries come from a documented IP range. Throttling per-IP is OK for DoS but ineffective against forged-source replay attempts (which already fail signature anyway). Acceptable.

### L2 - Stripe::Webhook.construct_event is the only signature check; no replay protection beyond Stripe's tolerance
- Within the 5-minute tolerance window, a captured signed payload can be replayed N times. Validator's session-id idempotency catches the minted case but the dispute/refund handler doesn't check event.id (see M1).

### L3 - Solana::Keypair#inspect redaction is a turf-monster-local monkeypatch
- File: /Users/alex/projects/turf-monster/config/initializers/solana_keypair_safety.rb:6-7
- Note in-file: "A corresponding change should land in the solana-studio gem itself in a follow-up release." Until then any other consumer of solana-studio (or a future tool that imports the gem outside Rails) has the un-redacted inspect. Low because the only consumer today is this app, but the gem is public on RubyGems so anyone else using it inherits the foot-gun.
- Fix: push the redaction into the gem itself for the 0.4.3+ release.

### L4 - RAILS_LOG_LEVEL defaults to info; payment-flow Rails.logger.info lines include amounts + user IDs
- Acceptable trade-off for the first month (debugging real-money flows is more important than minimal logs). Re-evaluate after week 4 - drop those lines to :debug once flows are stable.

### L5 - Pre-launch checklist items only partially enforced at boot
- Boot-fail enforcement exists for: STRIPE_SECRET_KEY (must be sk_live_), MANAGED_WALLET_ENCRYPTION_KEY (presence), EXPECTED_IDL_HASH (presence + match), SOLANA_PROGRAM_ID (presence), ENABLE_TEST_SCAFFOLDING (must be unset), SKIP_IDL_VERIFICATION (must be unset), MoonPay keys (when MOONPAY_ENABLED=true).
- NOT enforced at boot: SOLANA_NETWORK=mainnet-beta, SENTRY_DSN, SOLANA_RPC_URL looks like a paid endpoint (not api.mainnet-beta.solana.com), STRIPE_WEBHOOK_SECRET starts with whsec_.
- Fix: add a single MainnetSanityCheck initializer that fails boot if SOLANA_NETWORK == "mainnet-beta" and any of those sub-conditions don't hold. Pattern matches existing OPSEC-032 / OPSEC-014.
- Tier: pre-mainnet polish.

### L6 - Permissions-Policy header initializer is empty (all commented out)
- File: /Users/alex/projects/turf-monster/config/initializers/permissions_policy.rb
- Minor defense in depth - set policy.payment :self and policy.usb :none (Phantom doesn't need WebUSB), policy.camera :none, policy.microphone :none.

### L7 - Two redundant on-chain INIT_AUTHORITY / MULTISIG_COSIGNER env vars both default to the same Alex Phantom key
- File: /Users/alex/projects/turf-monster/app/services/solana/config.rb:31-37
- Documented in-file; intentional. Flagging only so the operator remembers to rotate them independently if the cosigner role ever moves.

### L8 - Sidekiq Web admin gate is custom middleware, not standard Rack::Auth::Basic + IP allowlist
- File: /Users/alex/projects/turf-monster/config/routes.rb:7-37
- The custom middleware reads User.find_by(id: user_id) per request and checks user.admin?. Functionally correct, but: (a) the route /admin/jobs is enumerable from a 404 vs 302 timing distinction (the middleware returns 404 for non-admins, 302 for unauth); (b) no IP allowlist as defense in depth.
- Fix: add a route constraint OR an IP allowlist via env var (SIDEKIQ_ALLOWED_IPS). Not urgent.

---

## Informational

### I1 - RubyGems 2FA / GitHub 2FA for operator
- Out of scope to audit from inside the repo, but the operator must confirm: (a) RubyGems account that publishes studio-engine and solana-studio has MFA via gem otp or a TOTP device; (b) GitHub account amcritchie has 2FA enforced for the repos owning these gems; (c) RubyGems API key is scoped/rotated (currently published gems can be re-released by anyone with the API key).

### I2 - Heroku account hardening
- Confirm Heroku account has MFA and that the HEROKU_API_KEY value stored in ~/.zprofile (per the "Agent-shell secrets pattern" memory note) has an associated audit trail. Heroku exposes heroku auth:whoami but does not show key creation date - rotate quarterly.

### I3 - Solana::Config::PROGRAM_ID fallback in dev is the orphaned-on-devnet program
- File: /Users/alex/projects/turf-monster/app/services/solana/config.rb:12
- Default Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT is the current devnet ID. Memory note project_turf_program_id_migration_2026_05_18.md flagged that the old 7Hy8...r2J literal was still in some docs; the code value here is the new one. OK.

### I4 - solid_queue config exists in mcritchie-studio but :async is the actual adapter
- File: /Users/alex/projects/mcritchie-studio/config/environments/production.rb:73-75
- mcritchie-studio still uses config.active_job.queue_adapter = :async - jobs run in the web dyno thread pool and are lost on restart. Not load-bearing for the launch (mcritchie-studio is the SSO hub, not a money app) but it means any auth-side job (email send, error notification fan-out) is unreliable. Out of scope for turf-monster mainnet launch, file as separate ticket.

### I5 - Webhook + faucet endpoints correctly skip auth filters
- All four skip_before_action :require_authentication / :detect_geo_state / :require_profile_completion calls are present and correct on the webhook controllers. CSRF skip is mandatory for Stripe/MoonPay POSTs and correctly limited to those controllers.

### I6 - :secure cookie on turf-monster is gated by Rails.env.production?
- Correct, but worth a note: if you ever run RAILS_ENV=staging, the cookie will not be Secure. Tie cookie hardening to a request-protocol check (secure: true if request.ssl? won't work in an initializer; use Rails.application.config.force_ssl as the predicate instead).

---

## Pre-mainnet checklist - state of each item

| Item | State | Notes |
|---|---|---|
| Mainnet RPC URL configured | Not yet - devnet default in Solana::Config:14 | Add boot-time check (L5) |
| Stripe live keys vs test keys | Enforced at boot (stripe.rb:13-15) and at deploy (bin/deploy:108-114) | Solid |
| MoonPay live keys (OPSEC-035) | Deferred; MOONPAY_ENABLED=true will trigger boot-fail-on-missing | M3 still owes the re-fetch validator |
| SENTRY_DSN set | Not set | H1 - block launch |
| ENABLE_TEST_SCAFFOLDING off in prod | Enforced at boot (test_scaffolding_guard.rb:10-13) | Solid |
| Squads mainnet vault deployed | TBD per MAINNET_LAUNCH.md step 0 - operator action | M5 - all 3 keys in operator hands |
| SKIP_IDL_VERIFICATION unset in prod | Enforced at boot + bin/deploy:100-105 | Solid |
| BYPASS_IDL_CHECK not present | Soft (logs warn; no audit) | M4 |
| SOLANA_NETWORK=mainnet-beta alignment | Enforced at boot via genesis hash check (solana_network_alignment.rb) | Solid for code; runbook step 6 sets the vars |
| MANAGED_WALLET_ENCRYPTION_KEY set | Enforced at boot + 1Password backup | Solid |
| config.hosts set | Not set - both apps | C2 - block launch |
| Cookies hardened on SSO hub | Not set on mcritchie-studio | C1 - block launch |
| Rack-attack on SSO hub | Not present | H4 - block launch |
| CSP nonce / strict-dynamic | Inline + unsafe-eval still on | H2 - at least add report-uri before launch |
| Heroku log drain | None documented | H1 |
| Pre-commit secret scan | None installed | M9 |
| Git-history secret sweep | Not run (sandbox blocked) | M6 - operator must run locally |
| turfmonster.media / mcritchie.studio subdomain inventory | Not documented in credentials.md | M8 |

---

## Recommended pre-launch action order

1. C1 - copy session_store.rb to mcritchie-studio. ~5 min, blocks launch.
2. C2 - add config.hosts to both apps. ~10 min, blocks launch.
3. H1 - provision Sentry, set SENTRY_DSN on both Heroku apps, add to MAINNET_LAUNCH.md step 6. ~30 min.
4. H4 - add rack-attack to mcritchie-studio. ~20 min.
5. H3 - add throttles for wallet withdraw / deposit / entry / change_password / signup. ~30 min.
6. H2 (partial) - add CSP report-uri and switch to report-only in staging to baseline violation rate before the nonce refactor. Drop unsafe_eval. ~1 hour.
7. M6 - operator runs git-history sweep locally. ~15 min.
8. M9 - install gitleaks pre-commit. ~20 min.
9. L5 - write MainnetSanityCheck initializer. ~30 min.

Total: a focused day. Nothing here requires touching Anchor code or business logic.

---

## Post-launch (week 1-2)

- M3 - MoonPay re-fetch validator before enabling MoonPay
- M5 / C3 - Mason's mainnet key into genuinely separate custody
- M1 - WebhookEvent idempotency table for refund/dispute redelivery safety
- H2 (full) - CSP nonce + :strict_dynamic refactor; hoist inline Alpine x-data factories into Alpine.data() registrations
- L3 - push keypair #inspect redaction into solana-studio gem itself
- L8 - Sidekiq admin IP allowlist
- I4 - mcritchie-studio off :async adapter
