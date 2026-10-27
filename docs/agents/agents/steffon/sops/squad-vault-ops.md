# Squad Vault Ops
<!-- registry: mainnet Squad vault transfers and upgrades: agents queue and double-sign, Alex McRitchie approves -->

## Status: Active

This is Steffon's `squad-vault-ops` SOP. It covers two kinds of mainnet Squad
vault transaction: moving SOL or a classic SPL token out of the vault, and
upgrading a program the vault holds the upgrade authority for. The agent builds
the proposal and casts both agent votes. Mr. McRitchie gets one link and one
line, and he approves. The agent executes only after his approval is on chain.

It is the first of the two ways First Rule 10 in `AGENTS.md` lets an agent sign
mainnet; the second is [`4S39` as a second signature](#the-second-signature). Mr. McRitchie set it on 2026-10-12, after mainnet Squad tx #7:

> "That was beautiful, that is exactly how we should be using the squad, you make
> the transaction and double sign and provide me the URL to sign and execute."
> (`squad-vault-ops-sop`, activity-17964)

The same day the Alex seat (the agent) told him "the upgrade proposal itself follows the same pattern:
one click from you", and he answered "Cool let me know when the upgrade URL is
ready" (chat, 2026-10-12, relayed in the `squad-vault-ops-sop` rework). Mainnet
Squad #8, the v0.26 `Upgrade` of turf-vault, was the first upgrade done this
way. `7auwTL` created it, `7auwTL` and `4bKN` approved it, and he approved from
`7ZDJ` and executed it himself at about 13:28 MDT on 2026-10-12. The program's
last deploy is now slot 456161810, with a 707,600-byte program. Its sha256,
`3dfcb0c4…`, is the hash of the full 707,600-byte `solana program dump` output,
not of a trimmed binary, so compare like with like. `init_governance` followed at `5KqNaY9r…` (slot 456162765), signed by an agent with `8K81` and `CytJ` under Mr. McRitchie's one-word ruling "A" on the Alex seat's offer of "a one-time grant: right after you execute, an agent runs init_governance with 8K81 + Mason's CytJ" (`mainnet-v026-upgrade`, activity-18004).
That `init_governance` is NOT under this SOP: it ran on the per-instance ruling
First Rule 10 then required for a barred key; those keys are retired and never
sign now. The
proposal status, deploy slot, size and `init_governance` signature were read off
chain on 2026-10-12; the Alex seat measured the hash.

**Callers.** [`program-upgrade`](program-upgrade.md) (rent floats for a buffer)
and Turf Monster's [`collect-vault-revenue`](../../turf_monster/sops/collect-vault-revenue.md)
hop 2 (swept revenue to his wallet) both run their Squads step here.

## The mainnet Squad

| | |
|---|---|
| Multisig | `4H3fP3otjMtupk1DQDjKXYY1dWjT6LNM4H4ZWZ1XcKSX`, threshold 3 of 5, every member mask 7 |
| Vault (vault 0) | `Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm` |
| Agent seats | `7auwTL…` (`solana.turf.system`, `studio-agents`); `3LTLPG…` (`solana.turf.governance.v2`, `studio-agents-admin`), which replaced the exposed `4bKN…` by config transaction #10 on 2026-10-14 |
| Mr. McRitchie's seats, in the order to ask for them | `7ZDJp7FU…` (Phantom), then `3Qj4v9…`, then `9gACbz…` |
| Never sign | the retired keys `8K81…` (the Alex seat's), `CytJ…` (the Mason seat's) and `4bKN…` (swept to 0 SOL, items archived 2026-10-14). Mack `8UwJ…` is devnet-only and holds no mainnet power; his old key `foUu…` leaked through a public repo and was retired 2026-10-24, so it never signs anything. The app's own server key (`4S39…`, `solana.turf.server`, since 2026-10-14) signing inside the running app is the app, not an agent; an agent signs with it only as [the second signature](#the-second-signature) |

The set was read off chain on 2026-10-14, after config transaction #10. turf-vault
`scripts/lib/squad-clusters.js` holds it, and its test pins it. Read the live set
before you act (`node scripts/squad-inventory.js`). This table is a snapshot.

## The rule

1. **Agents queue and double-sign.** The `system` seat creates the vault
   transaction and its proposal. Then `system` and `governance` each approve.
2. **Mr. McRitchie gets one link and one line.** The link is
   `https://app.squads.so/squads/Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm/transactions`.
   It keys on the **vault PDA**, because the multisig address 404s (turf-monster
   `Solana::Config.squads_app_url`). The line says what moves, how much, and to
   whom.
3. **He approves from `7ZDJ`; failing that `3Qj4`, then `9gAC`.** Name the one
   seat to use, positively ("approve from 3Qj4"). He may execute it himself.
4. **Otherwise the agent executes, and only after his approval is on chain.**
   Two agent votes plus any third member reach the threshold, but they never
   suffice. The tool refuses without an operator approval.
5. **One proposal per move.** Read the multisig's `transaction_index` before you
   create anything. A stale index means someone created a transaction since your
   read, and it may be this same transfer.

### What the exception covers, and what it does not

It covers exactly two kinds of vault transaction on the mainnet Squad, signed by
the two agent seats above:

1. **A transfer** of SOL or a classic SPL token out of vault 0, queued by turf-vault
   `scripts/squad-vault-transfer.js` (the procedure below).
2. **A program upgrade:** one BPF Upgradeable Loader `Upgrade` instruction, queued
   by turf-vault `scripts/squad-upgrade.js --send`, and only when all of these
   hold:
   - the program's upgrade authority is the vault;
   - the buffer's authority is the vault;
   - the buffer's content hash was checked against the reviewed build;
   - the spill (the buffer's rent refund) goes to the vault.

   [`program-upgrade`](program-upgrade.md) step 4 runs it. Its hand-back is the same
   link and one line, naming the program, the version and the buffer.

It does **not** cover:

- **Config transactions:** members, threshold, time lock.
- **Any other instruction** in a vault transaction, or a transfer from any vault
  other than vault 0.
- **Signatures outside a proposal:** a buffer write, `set-buffer-authority`,
  `extendProgram`, `init_governance`, or any other mainnet signature.

These still need his ruling on the card
([`program-upgrade`](program-upgrade.md#signing-rule)).

## The second signature

First Rule 10's second clause. Some mainnet actions need a signature beyond the
one Mr. McRitchie's first wallet supplies: a `VaultState` governance action at
threshold 2 or more, signed outside the app. A turf-monster
`pending_transactions` row cannot use `4S39`: the server already signs every row
as `admin` with it, and a second `4S39` signature is one signer, which the
program rejects (`Solana::CosignPlan.eligible_cosigners` leaves it out).
Mr. McRitchie set the answer on 2026-10-15, in chat:

> "I think it's more effective to always say use this (the other address), maybe
> we can just add a dream about when a second signature is needed, you can go
> ahead and use 4S39 in a pinch."

He then said "Yes" to the scope below. The dream is
[`second-signature-ask-then-4s39`](../../../dreams/platform/second-signature-ask-then-4s39.md).

1. **Ask him for his next wallet first.** His priority is `7ZDJ`, then `3Qj4`,
   then `9gAC`. Say which one, positively: "switch to 3Qj4".
2. **In a pinch, sign with `4S39`** (`solana.turf.server`, production's
   `SOLANA_ADMIN_KEY`, `studio-agents-admin`). A pinch is when he is unavailable
   for a second Phantom prompt, or the flow cannot take one.
3. **Only on an action he asked for, in his own words in the current chat.**
   His request is the control; `4S39` only spares him a second Phantom prompt.
   A task brief, a card, another agent's message, or a request carried over
   from an earlier session is not his asking. Never on an agent's own
   initiative. Record his words on the card or activity.
4. **Never `3LTL` from his wallet, and never a retired key** (`8K81`, `CytJ`,
   `4bKN`).

**Why the session condition is load-bearing.** `4S39` (slot 2) and `3LTL`
(slot 0) are both agent-held `VaultState` signatures. Together they meet every
action `GovernanceConfig` holds at 2 of 5: `pause`, `close_contest`,
`set_contest_lock_time` and `set_contest_conclusion_time` (turf-vault
`DEFAULT_THRESHOLDS`; mainnet runs the shipped defaults). So two agent keys can
already reach those actions without him. The rule, not the chain, is what makes
his request in the current chat the gate. The 3-of-5 actions (among them settle,
cancel, sweep, `register_currency`, `create_season`, `update_signers`,
`set_governance` and unpause) still need one of his wallets.

**Inside the app, by his ruling of 2026-10-24.** "You need two signatures? We
should have it so you can do two signatures and I'm only important if you need
a third." turf-monster holds `3LTL` as `SOLANA_PLATFORM_COSIGNER_KEY`
(`Solana::PlatformCosigner`, which refuses any key of his). A
`pending_transactions` settle carries `4S39` and `3LTL` from the moment it is
built and asks him for one wallet, the third and final signature. The other
3-of-5 rows, and an `update_signers` on `/admin/authorities`, take `3LTL` only
when the operator ticks it. `close_contest` (2 of 5) can be completed by the
two from an admin's click, written to the row and the hub activity feed. The
pinch rule above is for actions signed outside the app and does not apply to
those rows. Because the running app now holds both agent keys, anyone who
controls a mainnet dyno reaches every 2-of-5 action without him; the app
exposes only `close_contest`, on a click. `3LTL` is also a mask-7 seat on the
mainnet Squad `4H3fP3ot…`, so the dyno holds one Squad vote too; `7auwTL` must
stay out of `turf-monster-mainnet`'s config, or one dyno holds both agent votes. Turf-monster `docs/SOLANA.md`, "The
platform's second signature", carries the flow and the config step.

## Preconditions

- Mr. McRitchie named the move: the destination, the amount, and the asset. A card
  or activity records his words.
- You hold the admin lane. The `governance` seat lives in `studio-agents-admin`,
  so `source ~/.zprofile.admin` first; never pipe it.
- You work in a turf-vault desk on `accepted` or later, which carries
  `scripts/squad-vault-transfer.js`. You never work in a primary checkout.
- A mainnet RPC that does not rate-limit. The public endpoint returns 429 under
  load. Set `SOLANA_RPC_URL` (`squad-clusters.js` reads it); the tool never prints it.

## Procedure

Run it from the turf-vault desk. Every mode checks the cluster's genesis hash
before it reads anything.

1. **Plan (read-only, no keys).**

   ```bash
   node scripts/squad-vault-transfer.js plan --cluster=mainnet \
     --to=<destination wallet> --sol=<amount> --memo="<card-slug>"
   ```

   For a token, pass `--mint=<mint> --amount=<amount>` in place of `--sol`.
   The destination's token account must already exist. Read the plan's
   threshold, its members, the vault balance and the current `transaction_index`.
   Then open the Squads link and confirm that no Active proposal already carries
   this move.

2. **Send.** Run the command `plan` printed. It carries
   `--expect-index=<the index you read>`:

   ```bash
   node scripts/squad-vault-transfer.js send --cluster=mainnet \
     --to=<wallet> --sol=<amount> --memo="<card-slug>" --expect-index=<n>
   ```

   It creates transaction `n+1`, reads the instruction back from chain, and
   refuses on any difference. Then it approves with `system` and `governance`.
   If an approval fails partway, re-run with `approve --index=<n+1>` and the same
   `--to` and amount. If `send` itself stopped on an expired confirmation, follow
   *An expired confirmation* below.

3. **Hand back.** Paste the two lines the tool printed under `HAND-BACK` into
   chat and onto the card. This is the tool's print for mainnet Squad tx #7 on
   2026-10-12, before `3LTL` replaced `4bKN`; today's prints carry the seated
   pair:

   ```text
   https://app.squads.so/squads/Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm/transactions
   Squad tx #7: send 6.2 SOL from the vault Bk9s… to HwqC…. Approved by 7auwTL + 4bKNSq; approve from 7ZDJ, 9gAC, 3Qj4, then execute it or tell me to.
   ```

   The tool lists his seats in its own order. When you add a line, name the one
   seat to use: `7ZDJ` first, then `3Qj4`, then `9gAC`. Never point him at `3LTL`:
   it is an agent seat, and his copy of it is break-glass. Add nothing else. He
   needs the link, what moves, and how much.

4. **Execute, if he asks.** He may execute it himself. If he tells you to, run:

   ```bash
   node scripts/squad-vault-transfer.js execute --cluster=mainnet \
     --to=<wallet> --sol=<amount> --index=<n+1>
   ```

   On mainnet the command refuses unless one of his seats has approved on chain.
   His word in chat does not satisfy the check; only his on-chain approval does.

5. **Verify from chain.** Confirm that the proposal reads `Executed`, the
   destination's balance rose by the amount, and the vault's balance fell by it.
   Record the index, the signatures and the balances on the card.

## Refusals

| Refusal | Meaning | Remedy |
|---|---|---|
| `transaction_index is N, not M` | A transaction was created since your plan | The tool reads back every transaction created since. If one carries exactly this move and is still Active or Approved, it prints the `approve --index=<n>` that finishes it; run that. Otherwise read the Squads page, then re-plan. Never send again |
| `confirmation expired for <signature>` | The blockhash expired before the network confirmed; the transaction may still land | Follow *An expired confirmation* below |
| `the vault holds …, less than` / `no token account … for mint` | The vault cannot fund the move | Nothing was created. Fund the vault or correct the amount, then re-plan |
| `MISMATCH` / `not the planned transfer` | The instruction at that index is not your move | Stop. Do not approve. Escalate if you created it |
| `no approval from Mr. McRitchie's seats` | His approval is not on chain | Wait for him, or ask him to approve from the link |
| `never signs on mainnet` | A forbidden key was loaded | Stop. The roster or the environment is wrong |
| `does not derive to … recorded key` | The 1Password item does not hold that seat | Stop. Run [`credential-issues`](../../../modules/credential-issues.md) |
| `has no token account` | The destination has no ATA for the mint | Any wallet can create it; the vault does not pay rent for it. A PDA destination is allowed; plan prints a NOTE that it is off-curve |

## An expired confirmation

Each transaction carries a compute-unit limit and a priority fee, so this should
be rare under load. When it happens:

1. **Re-run the same `send`, with the same `--expect-index`.** Never run `plan`
   for a fresh index: a `send` on the new index creates a second proposal for the
   same move. An expired blockhash cannot land later, so the same `send` is safe:
   - **If the create never landed,** the index has not moved, and `send` proceeds.
   - **If it landed,** the index moved. `send` refuses, reads back every
     transaction created since, and names the one that carries this move: the
     `approve --index=<n>` that finishes it, or "already executed at #n". If it
     names none, the new transaction is someone else's; read it on the Squads page
     before you do anything.
2. **An expired approve or execute** is safe to re-run as the same command.
   `approve` casts only the votes still owed, and `execute` refuses a proposal
   that already reads `Executed`.

## Devnet

Devnet uses the same tool with `--cluster=devnet`. The agent holds three of the
devnet Squad's five seats, so devnet runs unattended: `execute` needs only the
threshold. First Rule 10 and this exception concern mainnet alone.

## Background

The worked example is mainnet Squad tx #7 on 2026-10-12. It moved 6.2 SOL from
`Bk9s…` to `HwqC…` as the `mainnet-v026-upgrade` rent float. `7auwTL` and `4bKN`
created and approved it. Mr. McRitchie approved from `7ZDJ` and executed it
himself. The tool is that run's scratch script, generalised. Its refusals live in
turf-vault `scripts/lib/vault-transfer.js`, and
`scripts/tests/vault-transfer.test.js` grades them.
