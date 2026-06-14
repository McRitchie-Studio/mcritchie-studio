# Signing console + auth feedback — for the v0.21 readiness pass

> From the turf-monster launch session, 2026-06-03. Two areas: (1) the v2 keyless
> signing console, (2) an auth bug surfaced while testing the shared-auth refactor.
> Goal: the console is production-ready to drive mainnet vault ops in the v0.21 era,
> and the shared auth doesn't pop Phantom on every refresh.

## Part 1 — Signing console (v2 keyless, two-browser durable-nonce)

The console looks right — keyless queue ("server holds no keys"), durable-nonce
two-browser form (cluster / instruction / nonce / admin+cosigner). Feedback, in
priority order:

1. **Do a full devnet dry-run before ANY mainnet use.** Build → Mason signs in
   browser A → Alex (`7ZDJ`) signs in browser B over the durable nonce → broadcast
   → **confirmed on-chain.** Run a harmless real op end-to-end (e.g. a no-op
   `update_signers` that keeps the same set). The durable nonce ("never expires
   while it waits") is the load-bearing claim — prove a half-signed tx actually
   sits and then lands. Don't trust the flow on mainnet until it's landed a devnet tx.

2. **Pin the signer set to the POST-ROTATION reality.** Live proof this bites:
   turf-monster's *local* env still had the leaked, rotated-out `F6f8` admin key,
   which caused a devnet `mint_entry_token` to fail with error 6000 ("Unauthorized:
   Only the vault admin can perform this action"). The console's defaults MUST map
   to the current VaultState 2-of-3 — **Alex-Bot `8K81…` + Mr. McRitchie
   `7ZDJp7…59Tcr` + Mason `CytJS…qWjrR`** — on BOTH clusters. The form shows "admin
   → Mason / cosigner → Alex 7ZDJ"; confirm those pubkeys are the rotated set and
   that there is **no stale `F6f8`** anywhere (defaults, nonce authority, fixtures,
   seeds).

3. **Mainnet parity — it's devnet-only in the current screenshots.** v0.21 ops run
   on **mainnet** (program `DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM`). Confirm
   cluster=mainnet fully works: a **mainnet durable-nonce account** exists + is
   selectable (turf-monster already provisioned `2bSnZ9d8NLJyGT3VgsjnU4Ncmm8yHcXnNKmepCeNDyiV`
   for create/entry — the console needs one with the right authority), and the
   mainnet program + VaultState + IDL all resolve.

4. **Register the v0.21 IDL + keep the byte-match safety check.** v0.21 changes the
   program (`create_contest` gains `name`/`slug`; new error codes 6039/6040/6041).
   The console's instruction encoders must be built from the **v0.21 IDL**
   (SHA256 `18a84fd11730a319a980688363928e6605b3b7b1390bc47de0c30336a00a2af5`),
   per-cluster — devnet may still be v0.18 until you upgrade it there too. Keep the
   "encode in Ruby → assert == known-good byte reference" gate before trusting any
   new instruction encoder.

5. **Make the boundary explicit: the console signs INSTRUCTIONS, it does NOT deploy
   the program.** The v0.21 `.so` UPGRADE is a Squads multisig op
   (`turf-vault/scripts/squad-upgrade.js`) + the `EXPECTED_IDL_HASH` re-pin in
   turf-monster — NOT a console action. Spell that out in the UI/docs so no one
   expects "deploy v0.21" from the console.

6. **Share the durable-nonce primitive with turf-monster.** turf-monster just
   shipped durable nonce (contest create + entry) on `solana-studio`'s nonce
   primitives. The console should reuse the SAME primitive (one place to maintain
   the nonce encoding/derivation/advance-ix), not a parallel implementation.

7. **(Scope) Instruction coverage.** `update_signers` is in. To be "the place to
   administer every contract," add the ops actually run: `settle_contest`,
   `sweep_operator_revenue`, `set_contest_lock_time`, `create_season`, and the
   single-signer `initialize`. Decide which of these move off turf-monster's
   Treasury cosign onto the console.

**Concrete bug observed:** turf-monster's local server log showed the console's
RPC-proxy polling **`/admin/signing/update_signers/rpc` 404 against
`turf-monster:3001`**. Looks like a v1 (`/admin/signing`) vs v2 (`/signing_requests`)
path mismatch, or the RPC proxy targeting the wrong app/origin. Worth a look.

## Part 2 — Shared-auth bug: Phantom unlock pops on every refresh

Surfaced testing the shared-auth refactor (on `main`): a **web2/managed user**
(server-held wallet, not Phantom) gets Phantom's **unlock prompt on every page
refresh**.

**Root cause:** the wallet watcher (`turf-monster/app/javascript/solana_stores.js`,
`Alpine.store('wallet').init`) fires `provider.connect({ onlyIfTrusted: true })` on
every page load whenever there's a server wallet address — gated only by
`if (!provider || !serverAddr) return`, NOT by session mode. So a web2 user still
triggers the probe, and an installed+previously-trusted Phantom pops its unlock to
check trust. Compounded by `MagicLinksController#consume` not resetting the prior
session — a previous web3/phantom-linked session's state bleeds into a new web2
magic-link session.

**Fix (turf-monster is implementing both now, on a branch for the release batch):**
1. Gate the watcher's Phantom probe + accountChanged subscription on the session
   actually being **web3** — a web2/guest/managed user must never invoke Phantom.
2. `MagicLinksController#consume` does a clean `reset_session` (clear onchain-session
   /web3 flags + `Current`) BEFORE establishing the new session, and clears stale
   `phantom_dl_*` / wallet-store localStorage on landing.

**Relevance to the shared-auth consolidation:** if/when SessionContext + the wallet
watcher move into `studio-engine`, bake this in at the engine level — the
"only-probe-Phantom-when-web3" gate and the "hard-reset-session-on-new-login" rule
should be properties of the shared auth, not per-app patches. Both apps benefit.
