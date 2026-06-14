# Squads Upgrade-Authority Migration Runbook

> **STATUS (2026-05-23): DEVNET COMPLETE ✓ — MAINNET STILL PENDING (no mainnet program yet).**
>
> Devnet upgrade authority for turf-vault `Dx8u…GaCT` is the Squads V4 vault
> `BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC` (multisig PDA
> `7nRuVw3VZFC6z85tYVDitPnaUHZCkqLpJRSTBNtPmtZB`, 2-of-3 Alex Bot / Alex /
> Mason). Migration was done programmatically via the Squads V4 SDK — see
> `turf-vault/scripts/squad-upgrade.js` for the reusable upgrade tool and
> `turf-vault/CLAUDE.md` "Deploying an upgrade" for the flow. Since the
> devnet migration, multiple upgrades have shipped through this path
> (turf-vault v0.13.0 → v0.14.0 → v0.15.0), so the workflow is now
> rehearsed and reusable.
>
> Related shipped work on the turf-monster side:
> - MANAGED_WALLET_ENCRYPTION_KEY (OPSEC-015) deployed to prod v80; reencrypt ran clean.
> - turf-monster verifies `EXPECTED_IDL_HASH` at boot + during `assets:precompile` (OPSEC-014).
>
> Remaining work (the **mainnet** migration) is **still pending** because
> there is no mainnet program yet — see Step 4 below. The steps in this doc
> apply verbatim once the mainnet deploy is ready.
>
> **Carried-over caveat:** operating the Squad with Alex Bot + Mason keys
> both in 1Password makes the 2-of-3 single-trust-domain until the human
> signers hold keys in separate domains.

> **When to read this:** You're about to move `turf-vault`'s program upgrade authority from a single keypair to a Squads multisig. Do this BEFORE mainnet launch.

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
   - Alex Bot: `F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ`
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

## Step 4 — Do it on mainnet

After devnet rehearsal succeeds:

1. Deploy the audited program to mainnet (this happens with the single key still as authority).
2. Smoke-test the mainnet deployment with the single key (a controlled deploy + verify).
3. Create a mainnet Squad with the same 3 signers (Alex Bot / Alex / Mason).
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

Update `turf-vault/CLAUDE.md`'s "Build & Deploy" section to reference this runbook rather than the current `anchor deploy --provider.cluster mainnet-beta` (which won't work post-migration).

## Open questions to resolve before mainnet

- Do we want a "break-glass" emergency upgrade keypair held by Alex only, paired with a strict legal/governance policy on when it can be used? Pros: faster response to exploits. Cons: re-introduces single-key risk.
- Are we comfortable with the existing 3 signers, or do we want to add a 4th (e.g. cold storage) before mainnet?
- What's the alert path if someone proposes an unexpected upgrade via Squads (someone other than us)?
