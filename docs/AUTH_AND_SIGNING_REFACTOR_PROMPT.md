# Kickoff prompt — shared auth + two-browser multisig console

> **ARCHIVE-ONLY PROMPT ARTIFACT.** Written 2026-06-02. Do not use this as the
> current auth or signing-console plan. Current agent onboarding starts at
> `/Users/alex/projects/AGENTS.md`; current app auth docs live in
> `mcritchie-studio/docs/topics/auth-and-sso.md`,
> `studio-engine/docs/GOOGLE_AUTH_SETUP.md`, and `turf-monster/docs/AUTH.md`.

---

You're working in the **McRitchie ecosystem** (`~/projects`): `mcritchie-studio` (admin/hub Rails app — "the studio"), `turf-monster` (Solana pick'em Rails app), `studio-engine` (shared Rails **engine gem**, consumed by both via `gem "studio-engine"`, `~> 0.4.x`, published to RubyGems), `solana-studio` (pure-Ruby Solana primitives gem).

**Original orientation note (historical):** read `mcritchie-studio/docs/ECOSYSTEM.md`, both apps' then-current agent docs, `turf-monster/docs/AUTH.md` + `docs/SIGNUP_FLOWS.md`, and the auto-loaded memory (especially the auth entries + `feedback-secret-handling-discipline`, `reference-phantom-inwallet-signing`, `feedback-prod-config-network-keyed`).

This is a real multi-repo refactor that touches **turf-monster's LIVE production auth** — **present a sequenced plan before writing code**, and keep turf-monster's ~590-test suite green throughout.

## Goal 1 — Common login options in mcritchie-studio
Give mcritchie-studio's login/signup screens the same three choices turf-monster has: **Google OAuth, Solana (Phantom) wallet, and passwordless email (magic-link)**.

## Goal 2 — Consolidate auth into `studio-engine` so BOTH apps share ONE flow
turf-monster has the mature implementation: passwordless **magic-link** (the only email auth — passwords were removed), **Google OAuth**, **Solana nonce/verify + a multi-wallet "Connect Wallet" modal**, all unified by `SessionContext` (modes: `web3`/`web2`/`guest`) + `Current`, magic-link delivered via Resend. Lift this common flow up into the **engine gem** and have both apps consume it; minimize per-app overrides.
- **Exception:** in mcritchie-studio the Web3 pieces (wallet auth + multisig signing) are *secondary* — it's primarily a web2/email/Google admin app, with Web3 available but not the default path.
- Extract **incrementally**; turf-monster auth is live in prod (don't break it). Version-bump `studio-engine` + `bundle update studio-engine` in consumers. Reference: turf-monster's `SolanaSessionsController`, `SessionContext`, magic-link mailer/consume, OmniAuth callbacks (merge support), and the inline Connect-Wallet Alpine component.

## Goal 3 — Two-browser multisig signing console in mcritchie-studio (v2 of an existing v1)
A **v1 already exists**: `mcritchie-studio/app/controllers/admin/signing_controller.rb` + `app/services/signing/` + `app/views/admin/signing/` + bundled IDLs in `config/idl/`; spec at `mcritchie-studio/docs/ADMIN_SIGNING_MODULE.md`. v1 builds a turf-vault instruction (Borsh-encoded in Ruby via `solana-studio`, **byte-match-verified** against a known-good reference), partial-signs with a **server-held** co-signer key (Mason), and serves a Phantom page for the human to add the 2nd signature. It works — it signed a real devnet `update_signers`.

Build **v2**, whose entire point is **NO signer private key in the repo or env** (this came from a key-leak incident — minimize where keys live):
- **Server is a pure coordinator** — it builds the unsigned transaction and only ever holds PUBLIC, half-signed transactions. It never signs and holds no keys.
- **Each signer signs in their own browser/session via their own Phantom** — e.g. Mr. McRitchie (`7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`) in one browser, Mason (`CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR`) in another. Two (or N) independent wallet signatures; no server cosigner.
- **Durable nonce account** instead of a recent blockhash, so a half-signed tx stays valid while it waits for the other signer (recent blockhashes expire in ~90s — too short for two people in two browsers). This is the canonical pattern for async multi-party signing.
- Model it as a **SigningRequest / pending-transaction** record — generalize turf-monster's existing `PendingTransaction` treasury-cosign pattern — and present a **table/queue view**: each row = one proposed instruction with status (awaiting-signatures / fully-signed / broadcast / failed), which members have signed, target program + multisig, and a sign link. Squads-style, so it scales to many ops across many contracts.
- **Support BOTH single-signer and multi-signer operations.** The console's job is *all* contract enablement + admin changes, so it must handle `initialize` (single-signer = the INIT_AUTHORITY's wallet; no nonce/multi-party coordination needed — just one Phantom signature, the canonical "enable a new contract" flow) as a first-class instruction alongside multi-sig ops like `update_signers` / `settle`. The operator's explicit intent: this is the standard place to bring up and administer every contract. (v1 left `initialize` as a TODO factory — implement it.)
- **Program-agnostic via an IDL registry** (per program + cluster) so it works for ANY future contract/multisig, not just turf-vault. Keep the **byte-match safety check** (encode in Ruby, assert it equals a known-good reference) before trusting any new instruction encoder.
- Admin-gated; safe to deploy to prod mcritchie-studio precisely *because* no keys live on the server. (Reuse `solana-studio` for encoding/PDAs.)

## Suggested sequence
Probably: (2) extract auth to studio-engine using turf-monster as reference → (1) wire mcritchie-studio's three login options on top → (3) build the v2 two-browser signing console. Goals 1 & 2 are intertwined; do them together. Plan first.
