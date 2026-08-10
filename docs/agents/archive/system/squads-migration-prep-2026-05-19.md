# Squads Upgrade-Authority Migration — Execution Prep

**When to read:** You're ready to execute `squads-upgrade-authority-migration.md` and want a precise, copy-pasteable sequence for the devnet rehearsal. This doc is the rehearsal companion to that runbook — the runbook is the authoritative spec; this is the *playable* version.

> **ARCHIVE-ONLY REHEARSAL SNAPSHOT.** This is a 2026-05-19 devnet migration
> script, not current deployment procedure. Verify current state in
> `turf-vault/docs/CURRENT_DEPLOYMENT.md` before reusing any command.

> **Dated rehearsal snapshot:** Do not treat wallet addresses or program IDs in
> this file as current source of truth. Before executing, verify the live signer
> set and deployment IDs in `turf-vault/docs/CURRENT_DEPLOYMENT.md`, then resolve
> private keys through McRitchie Studio's credential inventory and 1Password item
> names.

**Audit ref:** OPSEC-002 in `opsec-audit-pre-prod-2026-05-19.md`. Mainnet-blocking.

---

## What you need before starting

Verify each, then proceed:

```bash
# 1. Solana CLI configured for devnet
solana config get                # RPC URL should be api.devnet.solana.com
# Expected: 4AQMNwhyZtsaCLx3Dv9G5a2rXaJ6M221FYQw6sommRWz (your local id.json)

# 2. Funded with at least 1 SOL on devnet (Squad creation + buffer write + execute)
solana balance                   # need >= 1 SOL; use the Solana devnet faucet if needed

# 3. Program exists at the expected ID with you as current upgrade authority
solana program show Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT
# Expected: Authority: 4AQMNwhyZtsaCLx3Dv9G5a2rXaJ6M221FYQw6sommRWz (your wallet)

# 4. Phantom installed in browser with at least one of the multisig signer wallets
#    Verify which signers you actually hold private keys for:
echo "Alex Bot:  F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ  (server, op item agent.solana)"
echo "Alex:      7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr  (Phantom on this machine)"
echo "Mason:     CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR  (Mason's Phantom)"
```

If any of these fail, stop and fix before continuing.

---

## Phase 0 — Dry run on a throwaway devnet program (recommended)

Before touching `Dx8u…GaCT`, rehearse the whole sequence on a fresh disposable program. Cost: ~3 SOL of devnet rent (recoverable via `solana program close`). Time: ~15 min.

```bash
# Build a copy with a fresh keypair
cd /tmp && mkdir squads-dry-run && cd squads-dry-run
anchor init dryrun --no-git
cd dryrun
solana-keygen new --no-bip39-passphrase --silent --outfile target/deploy/dryrun-keypair.json
DRY_RUN_ID=$(solana-keygen pubkey target/deploy/dryrun-keypair.json)
echo "Dry-run program ID: $DRY_RUN_ID"

# Update Anchor.toml + lib.rs declare_id! to use $DRY_RUN_ID, then:
anchor build
solana program deploy target/deploy/dryrun.so \
  --program-id target/deploy/dryrun-keypair.json
solana program show $DRY_RUN_ID
# Authority should be your wallet
```

Then proceed through Phases 1-3 using `$DRY_RUN_ID` instead of the real program. At the end:

```bash
# Reclaim rent from the throwaway
solana program close $DRY_RUN_ID --bypass-warning
```

The cost of doing the dry run is small. The cost of fumbling the real migration is "program is immutable forever, all funds locked until force_close + new program deploy."

---

## Phase 1 — Create the Squad (web UI)

Squads CLI signing flow is fiddly; for the first time, use the web UI. ~5 min.

1. Open https://app.squads.so in the browser
2. Click **Network: Devnet** (top right). Verify URL shows devnet RPC.
3. Connect Phantom — connect with the Alex wallet (`7ZDJp…`).
4. **Create a Squad**
   - Name: `turf-vault upgrade authority (devnet)`
   - Threshold: **2 of 3**
   - Members:
     - `F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ` (Alex Bot)
     - `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr` (Alex)
     - `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR` (Mason)
5. Sign the create-transaction with Phantom.
6. After creation, click into the Squad's page and copy the **Vault PDA** (this is the new upgrade authority).

```bash
# Save the vault PDA — used in every subsequent step
export SQUAD_VAULT_DEVNET="<paste here>"
echo $SQUAD_VAULT_DEVNET   # confirm before proceeding
```

**Verify three times** (per main runbook §Step 5). Print it. Read it aloud. Cross-check the first 4 and last 4 chars match what the Squads UI shows.

---

## Phase 2 — Transfer upgrade authority on devnet

For the dry-run program, run against `$DRY_RUN_ID`. For the real migration, run against `Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT`.

```bash
PROGRAM_ID="${PROGRAM_ID:-Dx8uGU5w7B9NytDSsW4kseGZuqdVVRq1KY1mGXN2GaCT}"

# Final pre-flight confirmation
solana program show $PROGRAM_ID
echo "About to transfer upgrade authority to: $SQUAD_VAULT_DEVNET"
echo "Confirm (yes/no): "
read CONFIRM
[[ "$CONFIRM" = "yes" ]] || exit 1

# Execute the transfer
solana program set-upgrade-authority \
  $PROGRAM_ID \
  --new-upgrade-authority $SQUAD_VAULT_DEVNET \
  --keypair ~/.config/solana/id.json

# Verify
solana program show $PROGRAM_ID
# Authority: <SQUAD_VAULT_DEVNET>  ← MUST match
```

If the verify line shows anything other than `$SQUAD_VAULT_DEVNET`, the transfer didn't land — re-run `solana program show` after a few seconds; if still mismatched, contact someone before doing ANYTHING else. From this point on, future upgrades require Squad cosign.

---

## Phase 3 — Rehearse a no-op upgrade through the Squad

Critical: verify the upgrade flow works END-TO-END before considering the migration done. Without this rehearsal you don't know if you've bricked the program.

```bash
cd /Users/alex/projects/turf-vault

# Make a trivial change — bump a msg!() line in lib.rs:
#   msg!("...") → msg!("[v0.11.1] ...")
# Then rebuild:
anchor build

# Write the new binary to a buffer account
solana program write-buffer target/deploy/turf_vault.so
# Output: "Buffer: <BUFFER_ADDR>"
export BUFFER_ADDR="<paste from above>"
echo "Buffer is at: $BUFFER_ADDR"

# Transfer the buffer authority to the Squad vault so the Squad can apply it
solana program set-buffer-authority \
  $BUFFER_ADDR \
  --new-buffer-authority $SQUAD_VAULT_DEVNET
```

Now in the Squads web UI:

1. Open the Squad page → click **New Transaction** → **Program Upgrade**
2. Program ID: `$PROGRAM_ID`
3. Buffer address: `$BUFFER_ADDR`
4. Spill account: your wallet (gets the rent refund from the closed buffer)
5. Click **Create** — this signs as cosigner #1 (Alex).
6. Open the same proposal from signer #2's Phantom (Alex Bot via console, or Mason).
7. Cosigner #2 reviews → signs → quorum reached.
8. Click **Execute** to land the upgrade.

```bash
# Verify the upgrade landed
solana program show $PROGRAM_ID
# Last deployed slot should be in the last few minutes
```

If anything went wrong with the buffer (e.g. the upgrade fails to apply):

```bash
# Recover the buffer rent (only the buffer authority — now $SQUAD_VAULT_DEVNET — can close)
# This itself requires Squad cosign. If you haven't transferred buffer authority, just:
solana program close $BUFFER_ADDR --bypass-warning
```

---

## Phase 4 — Document the new state

After devnet success, update the following:

- `turf-vault/docs/CURRENT_DEPLOYMENT.md` — record the current upgrade authority and signer set
- `mcritchie-studio/docs/agents/system/credentials.md` — add a Squads section
- `mcritchie-studio/docs/agents/system/squads-upgrade-authority-migration.md` — strike through the "TODO" status, add the actual devnet Squad vault address as a worked example
- Memory: add a `project-squads-migration-devnet.md` recording the Squad vault PDA + the date

---

## Phase 5 — Mainnet (when you're ready)

Once devnet is rehearsed AND the external audit is complete AND you're about to deploy mainnet:

1. Deploy the audited program to mainnet using the single key (last time you'll use it for an upgrade).
2. Smoke-test the mainnet deployment.
3. Create a mainnet Squad with the same 3 members + threshold 2.
4. Repeat Phase 2 + Phase 3 against mainnet using `$SQUAD_VAULT_MAINNET`.
5. **Cold-backup the old single keypair**: `~/.config/solana/id.json` retains SOL for fees but no longer controls the program. Move it to a sealed offline storage. Remove it from every dev machine.
6. Update `squads-upgrade-authority-migration.md` with the mainnet Squad vault address.

---

## Operator self-check

Before executing any of this — particularly Phase 2's irrevocable `set-upgrade-authority` — confirm you can answer YES to each:

- [ ] I've read `squads-upgrade-authority-migration.md` (the main runbook) end-to-end
- [ ] I've completed the dry-run on a throwaway program
- [ ] I've copied `$SQUAD_VAULT_DEVNET` and verified it three times against the Squads UI
- [ ] I'm on a stable internet connection (not in a cab, not at a conference)
- [ ] If something goes wrong, I know the recovery path (Phase 5 in the main runbook — Squad-cosigned `set-upgrade-authority` back to single key)
- [ ] I have at least one other multisig signer available right now to help cosign the rehearsal upgrade

---

## What I cannot do for you

These steps need operator hands (Phantom signing, Squads UI clicking, irrevocable on-chain ops):

- Creating the Squad (requires your Phantom + Alex's wallet)
- Confirming the Squad vault PDA via the Squads UI
- Running `solana program set-upgrade-authority` (irreversible without cosign once it lands)
- Cosigning the rehearsal upgrade via Phantom

What I can do once you've started: walk through any error, verify on-chain state via `solana program show` / `solana account`, help debug buffer/auth issues, update the runbook to reflect what actually happened.
