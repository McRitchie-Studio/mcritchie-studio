# Admin Signing Module — Design Spec (draft)

> Generalize the one-off mainnet `initialize` signing page into a reusable
> admin tool: **sign an arbitrary on-chain instruction with a human's Phantom
> key, without ever exporting the key.** Home: mcritchie-studio (defacto admin
> app). Proven pattern: the 2026-06-02 turf-vault mainnet initialize.

## Why this exists

Some on-chain instructions must be signed by a *specific human wallet* (e.g.
turf-vault `initialize` requires `INIT_AUTHORITY` = a Phantom key; a Squads
multisig can't substitute — it signs as the vault PDA, not the member). The
safe way is **Phantom signs in-wallet**; never export the private key to a
file. This module makes that a first-class, repeatable admin capability instead
of a hand-built throwaway page each time.

## What it must NOT do

- Never touch/export a private key. The agent/server holds no human key.
- Never embed an RPC API key in client JS (use a server-side proxy).
- Never broadcast on the operator's behalf — only the operator's Phantom signs+sends.

## Architecture (proposed)

Add `gem "solana-studio"` to mcritchie-studio (pure-Ruby Borsh/encode/PDA
primitives — already used by turf-monster). Then:

1. **`SigningRequest` (server-side, ephemeral)** — describes one instruction to
   sign: `{ program_id, idl (or idl ref), instruction_name, args, accounts/PDAs,
   expected_signer, cluster }`. Built server-side; the instruction is
   **Borsh-encoded in Ruby** (solana-studio) and the account list resolved
   server-side, then the encoded ix data + account metas are inlined into the
   page as a verified constant. (This is the load-bearing lesson from the
   one-off: in-browser Anchor-from-CDN encoding drifts by version — encode once,
   server-side, against the pinned IDL.)
2. **Signing page (ERB + a small JS module)** — Connect Phantom → assert
   `connected.pubkey === expected_signer` (refuse otherwise) → **Simulate**
   (fresh blockhash, `sigVerify:false`, show program logs, gate send on
   `err:null`) → fetch a fresh blockhash immediately before signing →
   `wallet.signAndSendTransaction` → show signature + explorer link.
3. **RPC proxy** — a server endpoint in mcritchie-studio that forwards JSON-RPC
   to the cluster's Helius URL (key stays in server env). Permissive CORS not
   needed since same-origin. Replaces the throwaway localhost proxy.
4. **Pre-validation** — a server action that builds the same tx and runs
   `simulateTransaction(sigVerify:false)` with the expected-signer pubkey, so
   the request is proven valid before the operator ever clicks.

## Genericity

Driven entirely by the `SigningRequest` inputs — works for any program/instruction
(turf-vault initialize / update_signers / set_lock_time, future programs). The
caller (a rake task, or another app via a signed link) supplies program id +
IDL + instruction + args + expected signer.

## Open decisions (need operator/Jasper input)

- **A. IDL source:** upload per-request vs a small registry of known program IDLs
  in mcritchie-studio. Registry is nicer for repeat ops; upload is simpler v1.
- **B. Cross-app use:** does turf-monster (and future apps) hand off to this hub
  to sign (a signed deep-link from the app → mcritchie-studio signing page), or
  is the module copied per-app? Hub hand-off centralizes the capability but adds
  a cross-app trust/redirect flow.
- **C. Scope of v1:** just the in-wallet signing page + RPC proxy + Ruby encode
  (covers the rotation re-init), or also the registry + cross-app hand-off.

## First proving ground

The v0.20 key-rotation **re-init** (turf-vault `initialize` on the new program)
— build the module, then dogfood it for that signature instead of another
throwaway page.
