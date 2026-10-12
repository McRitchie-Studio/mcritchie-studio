# Squad Vault Ops
<!-- registry: move funds out of a Squads vault: agents queue and double-sign, Alex approves -->

## Status: Active

This is Steffon's `squad-vault-ops` SOP. It moves SOL or a classic SPL token out
of a Squads vault, mainnet first of all. The agent builds the transaction and
casts both agent votes. Mr. McRitchie gets one link and one line, and he
approves. The agent executes only after his approval is on chain.

It is the sole exception to First Rule 10 in `AGENTS.md` (no agent signs
mainnet). Mr. McRitchie set it on 2026-10-12, after mainnet Squad tx #7:

> "That was beautiful, that is exactly how we should be using the squad, you make
> the transaction and double sign and provide me the URL to sign and execute."
> (`squad-vault-ops-sop`, activity-17964)

**Callers.** [`program-upgrade`](program-upgrade.md) (rent floats for a buffer)
and Turf Monster's [`collect-vault-revenue`](../../turf_monster/sops/collect-vault-revenue.md)
hop 2 (swept revenue to his wallet) both run their Squads step here.

## The mainnet Squad

| | |
|---|---|
| Multisig | `4H3fP3otjMtupk1DQDjKXYY1dWjT6LNM4H4ZWZ1XcKSX`, threshold 3 of 5, every member mask 7 |
| Vault (vault 0) | `Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm` |
| Agent seats | `7auwTL…` (`solana.turf.system`, `studio-agents`); `4bKNSq…` (`solana.turf.governance`, `studio-agents-admin`) |
| Mr. McRitchie's seats | `7ZDJp7FU…` (Phantom), `9gACbz…`, `3Qj4v9…` |
| Never signs mainnet | Xan `8K81…`, Mason `CytJ…`, Mack `foUu…` |

The set was read off chain on 2026-10-12. turf-vault
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
3. **He approves from `7ZDJ`, `9gAC` or `3Qj4`.** He may execute it himself.
4. **Otherwise the agent executes, and only after his approval is on chain.**
   Two agent votes plus any third member reach the threshold, but they never
   suffice. The tool refuses without an operator approval.
5. **One proposal per move.** Read the multisig's `transaction_index` before you
   create anything. A stale index means someone created a transaction since your
   read, and it may be this same transfer.

The exception covers only Squads vault transactions on the mainnet Squad, signed
by the two agent seats above. A buffer write, `extendProgram`, `init_governance`
or any other mainnet signature is not covered. It still needs his ruling on the
card ([`program-upgrade`](program-upgrade.md#signing-rule)).

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
   `--to` and amount. Never re-run `send`: it would create a second proposal.

3. **Hand back.** Paste the two lines the tool printed under `HAND-BACK` into
   chat and onto the card:

   ```text
   https://app.squads.so/squads/Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm/transactions
   Squad tx #7: send 6.2 SOL from the vault Bk9s… to HwqC…. Approved by 7auwTL + 4bKNSq; approve from 7ZDJ, 9gAC, 3Qj4, then execute it or tell me to.
   ```

   Add nothing else. He needs the link, what moves, and how much.

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
| `transaction_index is N, not M` | A transaction was created since your plan | Open the Squads page and find out what it is. It may be this move. Re-plan; never retry blind |
| `MISMATCH` / `not the planned transfer` | The instruction at that index is not your move | Stop. Do not approve. Escalate if you created it |
| `no approval from Mr. McRitchie's seats` | His approval is not on chain | Wait for him, or ask him to approve from the link |
| `never signs on mainnet` | A forbidden key was loaded | Stop. The roster or the environment is wrong |
| `does not derive to … recorded key` | The 1Password item does not hold that seat | Stop. Run [`credential-issues`](../../../modules/credential-issues.md) |
| `has no token account` | The destination has no ATA for the mint | Any wallet can create it; the vault does not pay rent for it |

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
