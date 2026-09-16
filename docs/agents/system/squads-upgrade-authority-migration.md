# Squads Upgrade-Authority Migration — 2026-05-23 Record (archive)

> **ARCHIVE-ONLY MIGRATION RECORD — NO STEP IN THIS FILE IS LIVE PROCEDURE.**
> This captured the 2026-05-23 Squads migration work before the current mainnet
> program existed. The migration it describes has since **completed on both
> clusters** — see **How it resolved** below. Execute nothing from this file, and
> read no address in it as current identity. Current authority, signer,
> deployment, and upgrade rules live in
> `turf-vault/docs/CURRENT_DEPLOYMENT.md`; key-rotation procedure lives in
> `turf-vault/docs/KEY_ROTATION.md`.

> **STATUS AS RECORDED ON 2026-05-23: DEVNET COMPLETE ✓ — MAINNET PENDING (no mainnet program yet).**
>
> Everything in this file except the **How it resolved** section below is the
> record of that day, kept as written apart from the two places where the
> retired Alex Bot key had to be defused — Step 1's member list and Step 4's
> item 3. Both edits are marked inline. For what is true now, read
> **How it resolved**.
>
> Devnet upgrade authority for turf-vault `Dx8u…GaCT` is the Squads V4 vault
> `BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC` (multisig PDA
> `7nRuVw3VZFC6z85tYVDitPnaUHZCkqLpJRSTBNtPmtZB`, 2-of-3 Alex Bot / Alex /
> Mason). Migration was done programmatically via the Squads V4 SDK — see
> `turf-vault/scripts/squad-upgrade.js` for the reusable upgrade tool and
> `turf-vault/docs/CURRENT_DEPLOYMENT.md` for the current upgrade rule. Since the
> devnet migration, multiple upgrades have shipped through this path
> (turf-vault v0.13.0 → v0.14.0 → v0.15.0), so the workflow is now
> rehearsed and reusable.
>
> Related shipped work on the turf-monster side:
> - MANAGED_WALLET_ENCRYPTION_KEY (OPSEC-015) deployed to prod v80; reencrypt ran clean.
> - turf-monster verifies `EXPECTED_IDL_HASH` at boot + during `assets:precompile` (OPSEC-014).
>
> Remaining work (the **mainnet** migration) was **still pending on
> 2026-05-23**, because there was no mainnet program yet — see Step 4 below.
> The steps in this doc were expected to apply verbatim once the mainnet deploy
> was ready. They no longer apply: the mainnet migration completed, and the
> world moved twice after it. See **How it resolved**.
>
> **Carried-over caveat, as written on 2026-05-23:** operating the Squad with
> Alex Bot + Mason keys both in 1Password makes the 2-of-3 single-trust-domain
> until the human signers hold keys in separate domains. Both of those keys have
> since left both Squads; the trust-domain question itself is live and belongs
> with the docs named at the top of this file, not here.

## How it resolved

> **Read this before anything below it.** The mainnet half recorded above as
> "still pending" is **done**. Every bullet here was re-derived directly from
> chain at `finalized` on **2026-09-16**; nothing in it was taken from this file
> or from any other doc.
>
> - **Mainnet program `DaFv83yo…` already holds its upgrade authority on the
>   Squads vault `Bk9sS7ii…`** — Step 4's whole objective. That vault is
>   **derived**, as index 0 of multisig `4H3fP3ot…` under the Squads V4 program;
>   it is a different account from the multisig and will never equal it, so
>   derive it rather than comparing addresses. Mainnet's last deploy landed at
>   2026-06-11T15:15:51Z (slot `425788802`), which bounds the migration: the
>   authority was already on the vault by then. Devnet's last deploy was nine
>   minutes earlier (slot `468716417`, 2026-06-11T15:06:34Z), on the Squads
>   vault `BW13kgfi…`.
> - **Both Squads read threshold 3 of FIVE members today**, every member mask 7
>   (Initiate|Vote|Execute) — not the 2-of-3 this file plans for.
> - **The two clusters carry different membership**, and neither carries the
>   three seats named in Step 1. Derive the set per cluster; never carry one
>   cluster's roster or vault address to the other.
> - **`F6f8…KzhZ`, the "Alex Bot" key Step 1 pastes, is retired** — it was the
>   leaked key of the 2026-06 Alex Bot compromise
>   (`turf-vault/docs/KEY_ROTATION.md`). It sits on neither Squad, and it must
>   never be placed on a multisig again.
>
> The live rosters are deliberately kept out of this file — a second copy is a
> second thing to go stale, and this file going stale is what put it on the
> board. Read `turf-vault/docs/CURRENT_DEPLOYMENT.md` for deployment identity
> and `turf-monster/MAINNET_LAUNCH.md` for the per-cluster Squads membership,
> and re-derive from chain before you act on either.

> **When to read this — as framed on 2026-05-23:** You're about to move `turf-vault`'s program upgrade authority from a single keypair to a Squads multisig. Do this BEFORE mainnet launch.
>
> **When to read it now:** only to see how that move was designed and rehearsed. If you are about to perform or approve an upgrade, read `turf-vault/docs/CURRENT_DEPLOYMENT.md` and `turf-vault/docs/KEY_ROTATION.md` instead.

## Why this matters

`turf-vault` already has a **transaction-level** 2-of-3 multisig — settlement, force-close, and signer rotation all require two distinct signers from `VaultState.signers[]`. Good.

But the **program upgrade authority** is still a single keypair (`~/.config/solana/id.json`). Whoever holds that one key can ship a malicious program upgrade with zero cosign. That's the single biggest risk surface left on the program.

This migration moves upgrade authority to a Squads multisig with the same 2-of-3 quorum, closing the gap. After migration, an upgrade requires the same 2-of-3 cosign as a treasury op.

## When to do this

- **Before mainnet** — strict prerequisite. Don't deploy to mainnet with single-key upgrade authority.
- **After external audit** — the audit may surface findings that require an upgrade; do that with the single key, then migrate.
- **Optionally on devnet first** — recommended dry run so you can rehearse the workflow.

## Prerequisites

- All 3 multisig signers (Alex Bot / Alex / Mason) have:
  - Solana CLI installed + funded with SOL on the target cluster
  - Phantom (or any Squads-compatible wallet) configured
- The current upgrade authority key (`~/.config/solana/id.json`) is in your possession
- The deployed program ID: `7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J` (devnet)
- A clear maintenance window — once authority transfers, no upgrades possible without 2-of-3 cosign

> **Dated migration snapshot:** Verify current program IDs, Squad vaults, and
> signer addresses in `turf-vault/docs/CURRENT_DEPLOYMENT.md` before executing
> any command from this runbook. Resolve private keys through 1Password item
> names, not copied addresses in this document.

## Step 1 — Create the Squads multisig

```bash
# Install Squads CLI (if not already)
npm install -g @sqds/sdk
# Or use the web UI at https://app.squads.so

# Create multisig with 2-of-3 threshold + same signers as VaultState
# (web UI is easier for the first time)
```

Via web UI (https://app.squads.so):
1. Connect Phantom as Alex (or Alex Bot if you have its keypair handy).
2. "Create a Squad" → 2 of 3 threshold.
3. Add members:
   - Alex Bot: `F6f8…KzhZ` — **RETIRED (leaked, 2026-06). Never place this key
     on a multisig again.** The full address is redacted from this step
     deliberately: a pasteable address sitting in an imperative "add members"
     line is exactly how a retired key gets re-seated. It is on neither Squad
     today.
   - Alex: `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`
   - Mason: `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR`
4. Confirm and note the **Squad vault PDA** (this will be the new upgrade authority).

**Verify the Squad vault PDA** by clicking through to the multisig page. Copy the vault address. Call it `$SQUAD_VAULT`.

## Step 2 — Test transfer on devnet first

**Don't skip this.** Practice the entire flow on devnet so you have muscle memory before doing it on mainnet.

```bash
# Set devnet
solana config set --url devnet

# Verify current upgrade authority (should be single keypair)
solana program show 7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J
# Look for "Authority: <single-key>"

# Transfer upgrade authority to the Squad vault
solana program set-upgrade-authority \
  7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J \
  --new-upgrade-authority $SQUAD_VAULT \
  --keypair ~/.config/solana/id.json

# Verify
solana program show 7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J
# Should show "Authority: $SQUAD_VAULT"
```

## Step 3 — Rehearse an upgrade through the Squad

While still on devnet, do a no-op upgrade to confirm the cosign flow works:

1. Make a trivial change (e.g. bump a `msg!` log line in `lib.rs`).
2. `anchor build`.
3. Build the upgrade IX as a Squads proposal:

```bash
# anchor deploy normally tries to invoke set_upgrade — that fails now
# because the authority is the Squad vault. Use Squads CLI/UI to wrap:
solana program write-buffer target/deploy/turf_vault.so
# Note the buffer address — call it $BUFFER_ADDR

# In Squads web UI:
#   1. New proposal → "Program upgrade"
#   2. Program ID: 7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J
#   3. Buffer: $BUFFER_ADDR
#   4. Submit (this signs as cosigner #1)
#   5. Have signer #2 open the Squad page, review, sign
#   6. Once threshold met, anyone can "Execute" to land the upgrade
```

4. Verify the upgrade landed:
```bash
solana program show 7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J
# Last deployed slot should be recent
```

5. If anything went wrong, you still have the buffer — close it to recover rent:
```bash
solana program close $BUFFER_ADDR
```

## Step 4 — Do it on mainnet ✅ DONE (2026-06-11 at the latest), NOT AS PLANNED

> **This step is closed — there is nothing here left to perform.** Mainnet's
> upgrade authority is already the Squads vault `Bk9sS7ii…` (index 0 of multisig
> `4H3fP3ot…`), re-derived on chain 2026-09-16. The plan is reproduced below as
> the record of what was intended, with the one instruction that would now be
> dangerous struck through.

After devnet rehearsal succeeds:

1. Deploy the audited program to mainnet (this happens with the single key still as authority).
2. Smoke-test the mainnet deployment with the single key (a controlled deploy + verify).
3. ~~Create a mainnet Squad with the same 3 signers (Alex Bot / Alex / Mason).~~
   **SUPERSEDED — do not do this.** The mainnet Squad exists and is **3-of-5**,
   and two of those three names are off it: `F6f8…KzhZ` is retired and must
   never be re-seated, and Mason's key sits on neither cluster. The clusters
   carry different membership. Derive each cluster's set from chain, or read the
   per-cluster table in `turf-monster/MAINNET_LAUNCH.md`; never reuse the roster
   in Step 1.
4. Transfer authority:
   ```bash
   solana config set --url mainnet-beta
   solana program set-upgrade-authority \
     <MAINNET_PROGRAM_ID> \
     --new-upgrade-authority $MAINNET_SQUAD_VAULT \
     --keypair ~/.config/solana/id.json
   ```
5. Verify.
6. Do a no-op upgrade through the Squad to confirm the flow works on mainnet.
7. **Remove the old single keypair from `~/.config/solana/id.json` on every machine that has it, except as a sealed offline backup.** That keypair is now powerless on the program but still holds SOL for fees — store it as cold backup.

## Step 5 — Rollback plan

If the migration breaks something — e.g. the Squad vault address was wrong — there's only one path back:
- The new upgrade authority (the Squad vault) signs a `set-upgrade-authority` IX back to the old key.
- Requires 2-of-3 cosign through Squads.
- If somehow Squad is unreachable (lost signers, wallet bug), the program is **immutable forever**. That's actually OK for an audited program; if compromise is suspected, redeploy under a new program ID and migrate user balances via `force_close_vault` → re-init.

**To minimize rollback risk:** confirm the Squad vault address is correct THREE TIMES before running `set-upgrade-authority`. Print it. Compare. Have a second person verify.

## Verification checklist

> **The 2026-05-23 design, not a check to run.** Both Squads read threshold
> **3 of 5** today (every member mask 7), so the quorum and member-count lines
> below record what was planned rather than what to verify.

After migration, run through this checklist before declaring done:

- [ ] `solana program show <program_id>` → `Authority: <Squad vault PDA>`
- [ ] Squad has exactly 3 members + threshold 2
- [ ] Member pubkeys match VaultState.signers[] exactly (`anchor view` or Rails `Solana::Vault.signers`)
- [ ] No-op upgrade rehearsed and landed successfully (devnet AND mainnet)
- [ ] Old upgrade keypair physically isolated (cold backup) — not on any server, not in any 1Password vault that engineers routinely access
- [ ] Runbook for next upgrade documented (how to write buffer, how to propose via Squad UI, how to execute)

## Post-migration: ongoing upgrades

Every future upgrade goes through Squads:

```bash
solana program write-buffer target/deploy/turf_vault.so   # any signer can do this
# → submit upgrade IX via Squad UI → cosigner approves → execute
```

Update `turf-vault/docs/CURRENT_DEPLOYMENT.md` and `turf-vault/README.md` after any authority change. Do not update `turf-vault/CLAUDE.md`; it is migration context only.

## Open questions to resolve before mainnet

> **Recorded, not open.** Mainnet launched, and events overtook at least the
> second of these: both Squads now seat five members, not three. Raise current
> governance questions against the live docs named at the top of this file.

- Do we want a "break-glass" emergency upgrade keypair held by Alex only, paired with a strict legal/governance policy on when it can be used? Pros: faster response to exploits. Cons: re-introduces single-key risk.
- Are we comfortable with the existing 3 signers, or do we want to add a 4th (e.g. cold storage) before mainnet?
- What's the alert path if someone proposes an unexpected upgrade via Squads (someone other than us)?
