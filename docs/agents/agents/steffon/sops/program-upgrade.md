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
| `bin/program-drift` | Prints `PROGRAM DRIFT` per cluster that runs an older version than its source branch, with the upgrade card or "NO upgrade card" |
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
  `RUNBOOK.md`, *Deploy Failures*).
- **Mainnet**: **no agent signs a mainnet transaction.** The upgrade's human taps
  are Mr. McRitchie's two Squads approvals. An agent runs only reads and dry runs
  on mainnet: `squad-upgrade.js` without `--send`, `squad-inventory.js`,
  `check-signer-slots.js`, `bin/program-drift`. `squad-upgrade.js --send` casts
  the agent seats' approvals on mainnet (its HANDOFF path), so an agent never runs
  it armed against mainnet. The mainnet card names who writes the buffer and
  creates the proposal under this rule before the window opens.

## Preconditions

1. `bin/program-drift --fresh` prints `PROGRAM DRIFT` for the cluster, naming its
   card. A `cannot confirm` line is resolved first: a stale doc is re-derived
   (step 8), an unreadable chain is retried.
2. The version is on the program repo's `main`.
3. The version's own upgrade notes are read. They live in turf-vault's
   `RUNBOOK.md` (for v0.26, *v0.26 Upgrade Ordering*) and `CHANGELOG.md`.
4. For mainnet: the devnet card is done, and Mr. McRitchie is present for a
   quiet window.

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
   follow the signing rule above: Mr. McRitchie compares the Squads UI with the
   dry run's printed block, then approves and executes.
5. **Init steps, back to back.** Run what the version owes immediately after
   the upgrade lands. For v0.26 that is `scripts/init-governance.js` (dry run,
   then armed), because every vault-authorized instruction needs the account it
   creates (`RUNBOOK.md`, *v0.26 Upgrade Ordering*). On mainnet its signatures
   follow the signing rule.
6. **Signer set.** If the card rotates the vault's signers, run the ceremony in
   turf-vault's `docs/SIGNER_ROTATION.md`; otherwise confirm the set is untouched
   with `node scripts/check-signer-slots.js`.
7. **IDL pin in turf-monster.** Build the IDL, commit it as the consumer's
   `config/turf_vault.idl.json`, and set `EXPECTED_IDL_HASH` on the cluster's
   consumer app (QA for devnet, `turf-monster-mainnet` for mainnet) to the built
   file's hash. The app refuses to boot on a mismatch
   (`app/services/solana/config.rb`); turf-monster's `MAINNET_LAUNCH.md` carries
   the hash command.
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
v<version>` for the cluster, the card is `submitted` or later with its turf-vault
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
