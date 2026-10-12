# Program Upgrade
<!-- registry: on-chain program upgrade, devnet then mainnet, through Squads -->

## Status: Active

This is Steffon's `program-upgrade` SOP. It upgrades a deployed on-chain program
(today, turf-vault) to the version its source branch carries: **devnet first,
then mainnet**, each through the cluster's Squads multisig, with the init steps,
the consumer's IDL pin, the deployment record and a rehearsal in the same pass.

The release lane (`bin/release`, `qa-release`, `production-deploy`) ships Heroku
apps and never a program. This SOP is the program's lane. turf-vault v0.26
merged to main on 2026-10-11 with no upgrade card, and both clusters stayed on
v0.25.0 because nothing compared the source with the chain. Three seams now
catch that:

| Seam | What it does |
|------|--------------|
| `bin/program-drift` | Prints `PROGRAM DRIFT` per cluster that runs an older version than its source branch, with the upgrade card or "NO upgrade card"; and `UPGRADE RESERVE SHORT`/`LOW` when the reserve below cannot fund the next upgrade |
| `bin/release status` | Prints the same lines under **Programs**, so `qa-release` and `production-deploy` see them |
| `bin/dor-check` (merge phase) | Refuses a PR that bumps the program's version until every cluster's upgrade card is on the board |

The programs, their IDs, RPC endpoints, version file and deployment record are
in `config/onchain_programs.yml`. Logic: `bin/lib/program_drift.rb` and
`bin/lib/dor/checks/program_upgrade_cards.rb`.

## How drift is measured

The chain carries no version number. It carries the **slot of the last deploy**
(the ProgramData account's header). The program repo's
`docs/CURRENT_DEPLOYMENT.md` maps a slot to a version in each cluster's
`Version` and `Deployed … slot` rows. `bin/program-drift` reads the chain's slot,
and believes the doc's Version row only when the slots match. It then compares
that version with the `[package]` version in `programs/turf_vault/Cargo.toml`
on `main`.

| Line | Meaning |
|------|---------|
| `program turf-vault devnet: current at v0.26.0` | The chain runs what main carries |
| `PROGRAM DRIFT … chain runs v0.25.0 …, source is v0.26.0 — upgrade card devnet-v026-upgrade (designed)` | Behind, and the card that owns it |
| `PROGRAM DRIFT … — NO upgrade card: file devnet-v026-upgrade` | Behind, and nobody owns it: file the card (below) |
| `PROGRAM DRIFT … cannot confirm the deployed version — <reason>` | GitHub, the chain, the doc or the board could not be read, or the chain deployed since the doc was written. Never read this as current |

Exit codes: 0 every cluster current, 1 a cluster behind, 2 a cluster could not be
confirmed. A complete read is cached ten minutes; `--fresh` reads now.

## The upgrade reserve

**The mainnet Squad vault `Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm` is the
standing upgrade reserve** (Mr. McRitchie, 2026-10-12, activity-17926). It is
the program's upgrade authority, so it is already on every upgrade. Money moves
through it in a fixed loop:

1. **The float comes from it.** A Squad vault transfer
   ([`squad-vault-ops`](squad-vault-ops.md)) sends the buffer's rent, plus a
   little for fees, to a fresh single-use deploy key. For v0.26 that was mainnet
   #7, 6.2 SOL to `HwqC…`.
2. **Refunds go back to it.** The armed upgrade passes `--spill=<vault PDA>`, so
   the buffer's rent returns to the vault when the upgrade closes it. Then the
   deploy key's leftover is swept back to the vault, and the key ends with no
   account. For v0.26 the refund was #8's spill and the sweep was `vLXDwr4t…`
   (2.600795925 SOL).
3. **The stated minimum is the next float plus 1 SOL.** The next float is the
   rent-exempt minimum of a buffer the size of the program deployed now: the
   program's bytes plus the buffer's 37-byte header, at the rent the cluster
   quotes. On 2026-10-12, rent read 5,080 lamports per byte and the program was
   707,600 bytes, so the float was 3.5954 SOL and the minimum 4.5954 SOL. The
   vault held 10.3045 SOL. The 1 SOL of headroom covers fees, the deploy key's
   own rent, and a modest `extendProgram` if the next build is larger. A much
   larger build needs its extend priced separately, from the dry run.

`bin/program-drift` and `bin/release status` read the reserve on every run. The
reads are `getBalance` on the vault, the ProgramData size, and
`getMinimumBalanceForRentExemption`. All are read-only and need no key. The
account, its label and the 1 SOL headroom are the cluster's `upgrade_reserve` in
`config/onchain_programs.yml`. Logic: `ProgramDrift.reserve_readings`.

| Line | Meaning |
|------|---------|
| `upgrade reserve turf-vault mainnet: mainnet Squad vault Bk9s… holds X SOL; next float F SOL, minimum M SOL` | Funded: at or above the minimum |
| `UPGRADE RESERVE LOW …` | It covers the float but not the minimum. Top it up before the next window |
| `UPGRADE RESERVE SHORT …` | It holds less than the next float. No upgrade starts until Mr. McRitchie funds it |
| `UPGRADE RESERVE … cannot confirm — <reason>` | The chain could not be read. Never read this as funded |

A reserve line is a warning. It never changes `bin/program-drift`'s exit code and
never fails `bin/release status`. Devnet names no reserve: its upgrades float
from the agent seats under the devnet grant.

## The upgrade card convention

One card per cluster per version. The slug is the program's `card_slug`
template; turf-vault's is `{cluster}-{version}-upgrade`, where `{version}` is
`v<major><minor, two digits>`, plus `p<patch>` for a non-zero patch:

| Version | Devnet card | Mainnet card |
|---------|-------------|--------------|
| 0.26.0 | `devnet-v026-upgrade` | `mainnet-v026-upgrade` |
| 0.26.1 | `devnet-v026p1-upgrade` | `mainnet-v026p1-upgrade` |
| 1.2.0 | `devnet-v102-upgrade` | `mainnet-v102-upgrade` |

The board derives the slug from the title, so file each card by title. An
archived card does not count; every other stage does.

```bash
bin/task create --title "Devnet V026 Upgrade" --kind chore \
  --repo turf-vault --repo turf-monster --risk solana \
  --accept "Devnet program upgraded to v0.26 through the devnet Squad" \
  --test "[integration] bin/program-drift reads devnet current at v0.26.0"
bin/task create --title "Mainnet V026 Upgrade" --kind chore \
  --repo turf-vault --repo turf-monster --risk solana --risk payment \
  --depends-on devnet-v026-upgrade \
  --accept "Mainnet program upgraded to v0.26 in a quiet window" \
  --test "[integration] bin/program-drift reads mainnet current at v0.26.0"
```

File them in the PR that bumps the version: `bin/dor-check` refuses the bump
until both exist. A new program puts its own name in its `card_slug` template
so two programs' cards cannot collide.

## Signing rule

- **Devnet**: the agent seats on the devnet Squad drive the upgrade end to end.
  `scripts/squad-upgrade.js` takes its AUTONOMOUS path there (turf-vault
  `RUNBOOK.md`, *Deploy Failures*). Mr. McRitchie's grant of 2026-10-12 ("Your
  good with the admin access") lets the Steffon lane sign with admin-vault keys
  for devnet-only Squad votes, the devnet upgrade, and devnet
  `init_governance`/`update_signers`/`set_action_threshold`. The devnet
  `VaultState` holds three agent keys (`2eGs`, Mack `foUu`,
  `solana.turf.governance.devnet` `BVQH`), so every devnet governance action
  needs no human tap; turf-vault `docs/CURRENT_DEPLOYMENT.md` lists the set.
  No key is a `VaultState` signer on both clusters: when the mainnet rotation
  seats `9gAC` and `3Qj4`, Steffon rotates them off devnet in the same sitting
  (`scripts/rotate-devnet-signers.js`, signed by the three devnet agent keys),
  and turf-monster's `config/mainnet_vault_signers.yml` keeps every mainnet key
  fenced from the QA rehearsal.
  Load a key only into a process that prints its public half, and never pipe or
  redirect an `op read` of a secret (activity-17894 records why).
- **Mainnet**: **no agent signs a mainnet transaction** (First Rule 10), except
  for two kinds of Squad vault transaction under
  [`squad-vault-ops`](squad-vault-ops.md#what-the-exception-covers-and-what-it-does-not):
  1. a SOL or SPL transfer out of vault 0, such as the rent float for the buffer,
     through `squad-vault-transfer.js`;
  2. the upgrade proposal itself, through `squad-upgrade.js --send`. This holds
     only when the program's and the buffer's authority are both the vault, the
     buffer's hash matches the reviewed build, and `--spill` is the vault.

  For either, the agent seats `7auwTL` and `4bKN` create and approve the proposal.
  Mr. McRitchie approves from his own seat. An agent executes only after his
  approval is on chain. Mr. McRitchie set this on 2026-10-12 ("Cool let me know
  when the upgrade URL is ready"), and mainnet Squad #8 was the first upgrade
  done this way: he executed it at about 13:28 MDT, landing v0.26 at slot
  456161810. Config transactions and any other instruction are not covered.
- **The barred keys.** No agent runs a mainnet signature with `8K81`, `CytJ` or
  Mack unless Mr. McRitchie rules on that one instance. The app's own server key
  (`8K81` today) signing inside the running app is the app, not an agent. The
  v0.26 mainnet `init_governance` followed at `5KqNaY9r…` (slot 456162765), signed by an agent with `8K81` and `CytJ` under Mr. McRitchie's one-word ruling "A" on Xan's offer of "a one-time grant: right after you execute, an agent runs init_governance with 8K81 + Mason's CytJ" (`mainnet-v026-upgrade`, activity-18004).
  Outside the exception, an agent runs only reads and dry runs on mainnet:
  `squad-upgrade.js` without `--send`, `squad-inventory.js`,
  `check-signer-slots.js`, `bin/program-drift`.
- **The rule and the chain disagree, and only Mr. McRitchie settles it.** The
  mainnet Squad is 3-of-5, so two approvals of his do not reach quorum; and every
  step before them is itself a signed mainnet transaction: `write-buffer` and
  `set-buffer-authority` (payer funds the buffer rent, about 3.6 SOL at v0.26's 707,600 bytes), `extendProgram` if
  the dry run asks, then `vaultTransactionCreate` and `proposalCreate`. The
  rent is the reserve's float (*The upgrade reserve* above). The last
  two, and the two agent approvals after them, are the upgrade proposal, which the
  `squad-vault-ops` exception covers. The rest are not covered: `write-buffer`,
  `set-buffer-authority`, `extendProgram`, and `init-governance.js --cluster
  mainnet` (which takes keypair files only, so its two signatures are agent-run).
  **No agent runs any of those on mainnet until he records a ruling on the card
  naming each signer, key and payer.** The armed upgrade passes `--spill=<the
  vault PDA>`, so the buffer's rent refund returns to the vault and never lands
  on an agent seat.

## Preconditions

1. `bin/program-drift --fresh` prints `PROGRAM DRIFT` for the cluster, naming its
   card. A `cannot confirm` line is resolved first: a stale doc is re-derived
   (step 8), an unreadable chain is retried.
2. The version is on the program repo's `main`.
3. The version's own upgrade notes are read. They live in turf-vault's
   `RUNBOOK.md` (for v0.26, *v0.26 Upgrade Ordering*) and `CHANGELOG.md`.
4. For mainnet: the devnet card is done, and Mr. McRitchie is present for a
   quiet window.
5. For mainnet: `bin/program-drift --fresh` prints no `UPGRADE RESERVE SHORT`
   line. The reserve must cover the float before any proposal is built.

## Procedure

Run it once for devnet, then once for mainnet. Work in a turf-vault desk on
`main` (`bin/task begin <card-slug>`), never a primary checkout.

1. **Keep the rollback.** Dump the running program and record its SHA256,
   the commands under *Verification* in turf-vault's `docs/CURRENT_DEPLOYMENT.md`.
   Rolling back is the same Squads upgrade pointed at a buffer written from that
   dump.
2. **Build** from `main` and confirm the binary is the version you mean
   (`anchor build`; size and limits in `RUNBOOK.md`, *Deploy Failures*).
3. **Buffer.** `solana program write-buffer`, then `solana program
   set-buffer-authority` to the cluster's Squads vault PDA. The vault differs per
   cluster; read it from `docs/CURRENT_DEPLOYMENT.md` and confirm it with
   `solana program show <program-id> --url <cluster>` (`RUNBOOK.md`, *Deploy
   Failures*).
4. **Squads proposal.** `node scripts/squad-inventory.js` names the path the
   upgrade will take. `node scripts/squad-upgrade.js --cluster=<cluster> <BUFFER>`
   is the dry run; read its plan. On devnet, re-run with `--send`. On mainnet,
   follow the signing rule above. **STOP if the dry run plans an `extendProgram`.**
   `squad-upgrade.js --send` would sign the extend with an agent seat, and the
   exception does not cover it. Extend first, separately: with the single-use
   deploy key (as for v0.26, `HwqC…`), or as Mr. McRitchie rules on the card.
   Re-run the dry run, and go on only when it plans no extend. **The agent creates
   the upgrade proposal.** First confirm that the buffer's SHA256 matches the
   reviewed build and that the buffer's authority is the vault. Then run:

   ```bash
   shasum -a 256 target/deploy/turf_vault.so   # the reviewed build; the buffer is written without --max-len
   node scripts/squad-upgrade.js --cluster=mainnet <BUFFER> \
     --spill=<vault PDA> --expect-buffer-sha256=<that sha256> --send
   ```

   Since turf-vault PR 61 (`squad-tools-hardening`), a mainnet `--send` refuses
   before it reads a key unless `--spill` is given and is the Squad vault PDA, and
   `--expect-buffer-sha256` equals the sha256 of the buffer's program bytes. The
   dry run prints the buffer's own hash to compare. The `system` seat creates the proposal,
   and `system` and `governance` approve it. Hand Mr. McRitchie the proposal as
   [`squad-vault-ops`](squad-vault-ops.md) step 3 does: the Squads
   `/transactions` link on the vault PDA, and one line naming the program, the
   version and the buffer. **Then he approves**, after comparing the Squads UI
   with the block the run printed, from his own seat. He executes it, or tells
   the agent to execute once his approval is on chain. The buffer's SOL float
   comes from the upgrade reserve (above) through `squad-vault-ops` first. After
   the upgrade, sweep the deploy key's leftover back to the vault.
5. **Init steps, back to back.** Run what the version owes immediately after
   the upgrade lands. For v0.26 that is `scripts/init-governance.js` (dry run,
   then armed), because every vault-authorized instruction needs the account it
   creates (`RUNBOOK.md`, *v0.26 Upgrade Ordering*). On mainnet its signatures
   follow the signing rule: they need his ruling for that one run. For v0.26 an
   agent signed with `8K81` and `CytJ` under his ruling "A" (activity-18004).
6. **Signer set.** If the card rotates the vault's signers, run the ceremony in
   turf-vault's `docs/SIGNER_ROTATION.md`; otherwise confirm the set is untouched
   with `node scripts/check-signer-slots.js`.
7. **IDL pin in turf-monster.** Never overwrite `config/turf_vault.idl.json`: it
   is the running shape and the rollback. For v0.26 the new shape is already
   committed as `config/turf_vault{,.mainnet}.v026.idl.json`, selected only when
   `SOLANA_VAULT_GOVERNANCE` is on. Flip the hash and the switch in ONE config
   write on the cluster's app (QA for devnet, `turf-monster-mainnet` for mainnet),
   or the restart refuses to boot on the mismatch: `heroku config:set
   EXPECTED_IDL_HASH=<v025>,<v026> SOLANA_VAULT_GOVERNANCE=on`; roll back with
   `heroku config:unset SOLANA_VAULT_GOVERNANCE` (`app/services/solana/config.rb`).
   That write is step 9's consumer switch; do not split them.
8. **Re-derive `CURRENT_DEPLOYMENT.md` from chain.** After the upgrade,
   `bin/program-drift --fresh` prints `cannot confirm … chain last deployed at
   slot N but … records slot M`. That is the signal to re-derive the cluster's
   rows (Version, Deployed slot, Program SHA256, signer rows) with the
   *Verification* commands in the same doc, in a turf-vault PR.
9. **Consumer switch.** Turn on the consumer behavior the version enables (for
   v0.26, `SOLANA_VAULT_GOVERNANCE` on the cluster's app) through the
   turf-monster PR the card names.
10. **Rehearsal.** On devnet, run [`contest-rehearsal`](../../turf_monster/sops/contest-rehearsal.md)
    on QA from create to close. On mainnet, one routine settlement lands under the
    new version.
11. **Confirm.** `bin/program-drift --fresh` reads `current` for the cluster.
    Ship the card's PRs through the normal build lane
    ([`building-sop`](../../../modules/building-sop.md)).

## Exit Seam

`bin/program-drift --fresh` prints `program <name> <cluster>: current at
v<version>` for the cluster and no `UPGRADE RESERVE SHORT` line, the card is `submitted` or later with its turf-vault
and turf-monster PRs, `CURRENT_DEPLOYMENT.md`'s Deployed slot matches the chain,
the consumer's `EXPECTED_IDL_HASH` matches the built IDL, and the rehearsal is
recorded on the card. Report: cluster, version, program slot, IDL hash, rehearsal
evidence, and any `cannot confirm` line by name. Never report a cluster current
that the drift check could not confirm.

## Related

- turf-vault: `RUNBOOK.md` (*Deploy Failures*, *v0.26 Upgrade Ordering*,
  *Verifying Deployment*), `docs/CURRENT_DEPLOYMENT.md`, `docs/SIGNER_ROTATION.md`,
  `scripts/squad-upgrade.js`, `scripts/squad-inventory.js`,
  `scripts/init-governance.js`, `scripts/check-signer-slots.js`.
- [`production-deploy`](production-deploy.md) and
  [`qa-release`](../../avi/sops/qa-release.md): their exit seams read the drift
  lines; neither ships a program.
- [`../../../modules/gates/dor.md`](../../../modules/gates/dor.md): the version-bump card check.
