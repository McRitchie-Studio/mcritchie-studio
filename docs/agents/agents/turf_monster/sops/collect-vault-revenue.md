# Collect Vault Revenue

## Status: Active — mainnet runs turf-vault v0.25 today, and the signer count rises at v0.26

This is Turf Monster's `collect-vault-revenue` SOP. It takes accumulated
**operator revenue — entry fees** — out of the turf-vault `op_rev` ATA and
delivers it to Alex's own wallet.

**It is TWO hops, and the first one does not reach his wallet.** Read the next
section before running anything; a reader who believes one sweep finishes the job
will watch a confirmed transaction land money somewhere he cannot spend it, and
conclude something broke.

Run it when entry fees have accumulated and Alex asks for them — after a slate
settles, at the end of a month, or on request. Nothing schedules it and nothing
should.

It is Turf Monster's because the judgment it asks for is a contest judgment:
whether the revenue sitting in `op_rev` is really finished revenue, whether any
contest still owes a payout out of a pool that is funded separately, and how much
of the balance should leave the operator's control at all.

**It holds no release lane.** It signs on-chain transactions on `mainnet-beta`
and it writes one `PendingTransaction` row per sweep. It never touches `release`
or `main`, never promotes, and never deploys.

**What it does NOT do**, stated up front so nobody stretches it:

- **Not a payout.** Prize money leaves the `prize_pool` PDA through
  `settle_contest`, a different instruction with a different source account.
- **Not a prize-pool withdrawal.** `op_rev` and `prize_pool` are separate
  accounts; nothing here can reach a pool.
- **It does not create the treasury ATA.** No admin action does — see step 1.
- **It does not touch Squads membership or thresholds.** Changing who can approve
  hop 2 is Squads' own UI and a different decision.
- **It does not move SOL**, only SPL token balances, one mint per call.

## ⛔ It is two hops — and hop 1 does not reach your wallet

| Hop | Instruction / action | From → To | Where you run it | Signers | In our codebase? |
|---|---|---|---|---|---|
| **1** | `sweep_operator_revenue` (turf-vault) | `op_rev` ATA → **treasury** ATA | `/admin/currencies` → `/admin/pending_transactions` | **2-of-3** VaultState multisig | **Yes** |
| **2** | Squads transfer | treasury (Squads vault PDA) → personal wallet | `app.squads.so` | **3-of-5** Squads multisig | **No — nothing in turf-monster or turf-vault performs or prepares it** |

**Hop 1 ends inside the Squads vault, not in a wallet.** The program pins the
destination to the treasury authority — which IS the Squads vault PDA — so a
successful sweep moves the money from one account nobody can spend from to
another account nobody can spend from alone. It is now under 3-of-5 control
instead of 2-of-3, which is the point: the sweep is the bookkeeping move, hop 2
is the withdrawal.

**Hop 2 has no code, no job, no rake task, and no admin button.** Do not go
looking for one and do not build one in the middle of this SOP. It is a human in
a browser, three approvals, and an execute.

A sweep that confirms and a reader who stops there is the most expensive misread
available here, because every signal looks like success: the `PendingTransaction`
is `confirmed`, the signature is on chain, the `op_rev` balance is `0`, and the
money is still not his.

## The two multisigs are DIFFERENT — never write "the multisig" unqualified

Two multisigs govern the two hops. Different program, different addresses,
different membership, different thresholds, different interface. Turf Monster's
own config file carries the same warning, for the same reason: the unqualified
phrase is what produced the wrong-address claims it now forbids.

| | **VaultState multisig** (hop 1) | **Squads V4 multisig** (hop 2) |
|---|---|---|
| Governs | `sweep_operator_revenue` and every other turf-vault treasury op | The treasury vault's own balance, and the program upgrade authority |
| Threshold today | **2 of 3** | **3 of 5** |
| Members | three, named below | **five**; read them from chain, do not assume they are the three below plus two |
| Lives in | `VaultState`, the turf-vault PDA at seeds `[b"vault"]` | the Squads V4 program, multisig account `4H3fP3otjMtupk1DQDjKXYY1dWjT6LNM4H4ZWZ1XcKSX` (mainnet) |
| Interface | our admin UI (`/admin/currencies`, `/admin/pending_transactions`) | `app.squads.so` |
| Changed by | `update_signers` | Squads' own config transaction |

The three VaultState signers on mainnet, as `Solana::Config::MULTISIG_SIGNERS`
declares them:

| Slot | Address | Who |
|---|---|---|
| server admin | `8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd` | the app signs with this one automatically |
| cosigner | `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr` | Alex's Phantom — the default `MULTISIG_COSIGNER` |
| third | `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR` | Mason |

So hop 1 needs **one human signature**: the server already holds the admin slot,
and the cosigner slot is Alex's Phantom. Hop 2 needs **three**.

## The money model — why sweeping strands no payout

Confirm this before moving money, because the one thing that would make a sweep
dangerous is entry fees being part of a prize pool. They are not:

| Fact | Where |
|---|---|
| The entry fee transfers **user ATA → `op_rev` ATA** at entry time | `turf-vault/programs/turf_vault/src/instructions/enter_contest.rs` — the SPL transfer in `handle_enter_contest`; `enter_contest_with_token.rs` does the same |
| It never enters the prize pool | `settle_contest.rs` header: *"Entry fees are NOT included anymore — they sit in op_rev ATAs, separate from the prize pool"* |
| Payouts are a **fixed schedule per format**, not a share of fees | `Contest::FORMATS` in `turf-monster/app/models/contest.rb` |
| Pools are funded separately, at contest creation | the `prize_pool` PDA, seeded at `create_contest` — a different account from `op_rev`, reachable only by `settle_contest` and `cancel_contest` |

So the balance in `op_rev` is operator revenue already, and sweeping it **strands
no payout**. That is a fact about the accounts, not a judgment — but see the
split below for the judgment it leaves you.

## The split — read this before running anything

**You decide nothing about the destination or the amount reaching a wallet.** The
program pins where a sweep can go; Squads pins who may approve the withdrawal.

| Deterministic — the code | Agentic — you |
|---|---|
| The sweep destination (`treasury_ata.owner == vault_state.treasury_authority`) | Whether to collect at all, and when |
| Sweeping the FULL balance (the admin path always sends `amount: 0`) | How much should leave the Squads vault on hop 2 |
| Refusing an empty `op_rev` account, and a wrong-owner treasury ATA | Reading a refusal and choosing its remedy |
| Deriving both ATAs from the mint and the live `VaultState` | Confirming the destination wallet address with Alex |
| Enforcing 2-of-3 on hop 1, 3-of-5 on hop 2 | Collecting the other two Squads approvals |

If you find yourself reasoning about **which address the sweep should go to**,
stop. The program owns that, and the first live run lost a round trip to exactly
that reasoning — see the refusals table.

## Preconditions

- Alex asked for the collection, and **named the destination wallet** for hop 2.
- You know which **mint** you are collecting. One mint per call; in practice USDC,
  `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` on mainnet.
- You can reach `/admin/currencies` on the target app as an admin.
- **Alex has his Phantom available** — hop 1 needs his cosign, and hop 2 needs
  his plus two more Squads approvals.
- The turf-vault program on that cluster is not paused.

Everything below runs against production:

```bash
heroku run --no-tty -a turf-monster-mainnet -- bin/rails runner "<script>"
```

On devnet, the same reads run against `-a turf-monster-qa`, and hop 2 has no
devnet equivalent worth rehearsing — `devnet.squads.so` is decommissioned.

**Keep `$` out of these scripts.** A `heroku run … runner "<script>"` argument is
shell-expanded before the dyno sees it, so a `$` is eaten and the script arrives
mutilated. Nothing below uses one; if you add a line that needs one, send the
script over stdin instead.

## Steps

### Step 1 — Does the treasury ATA exist? Ask BEFORE you queue anything

**This is step 1 because its absence is only discoverable by attempting a sweep,
and there is no admin action that creates one.** `Admin::CurrenciesController`
has exactly four actions — `index`, `register`, `deactivate`, `sweep` — and none
of them creates an account. The first live run found this out the expensive way:
the sweep form answered *"Treasury ATA does not exist for this mint (create it
first)"* and left the operator with an instruction and no lever.

Read every address and both states in one go, and keep this output — it is the
before-picture step 4 compares against:

```ruby
vault = Solana::Vault.new
mint  = Solana::Config::USDC_MINT
state = vault.read_vault_state
abort("ABORT: could not read VaultState") if state.nil?

treasury_authority = state[:treasury_authority]
treasury_ata = vault.treasury_ata_for(mint)
op_rev_ata   = Solana::Keypair.encode_base58(vault.op_rev_ata_pda(mint).first)

puts "MINT               #{mint}"
puts "TREASURY_AUTHORITY #{treasury_authority}"
puts "TREASURY_ATA       #{treasury_ata}"
puts "OP_REV_ATA         #{op_rev_ata}"

info = vault.client.get_account_info(treasury_ata)
puts "TREASURY_ATA_EXISTS #{!info&.dig('value').nil?}"

bal = vault.client.get_token_account_balance(op_rev_ata)
puts "OP_REV_BALANCE #{bal&.dig('value', 'uiAmountString').inspect} raw=#{bal&.dig('value', 'amount')}"
```

**`TREASURY_ATA_EXISTS false` stops the SOP here**, and the remedy is the one
that worked on the live run:

> **Send 1 USDC from Phantom to the treasury authority address** — the
> `TREASURY_AUTHORITY` the script just printed, not the ATA. Phantom creates the
> recipient's associated token account as part of that transfer, and the ATA it
> creates is exactly the `TREASURY_ATA` above. **Nothing is wasted:** that 1 USDC
> is swept back to the treasury on hop 1, so it arrives with the rest.

Then re-run this step. `TREASURY_ATA_EXISTS` must read `true` before you touch
the sweep form.

**`OP_REV_BALANCE` of `0` also stops here** — there is nothing to collect, and
the sweep form will say so rather than queue a doomed transaction.

Measured on `turf-monster-mainnet`, 2026-09-29:

| | Address |
|---|---|
| USDC mint | `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` |
| `op_rev` USDC ATA | `2tuNmNzZH3x5FG7K9vzkfa9id3bCe89RWFGP5FD8aNs1` |
| treasury ATA | `5CJni4gAG3hjvAoHyJvdF9cksjDkAYGJz7mmRc87xa1T` |
| treasury authority (= Squads vault PDA) | `Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm` |

**Read them from the script, not from this table.** The addresses above are a
2026-09-29 reading, and `treasury_authority` is DATA in `VaultState` — one
`initialize` on a different cluster, or a future write, moves it. The script
resolves it live; the table is here so a wrong answer is recognisable, not so it
can be copied.

`/admin/currencies` prints the same treasury authority and each currency's
`op_rev` ATA on the page, if you would rather read it there.

### Step 2 — Queue the sweep

The admin path builds a partially-signed transaction and queues it for cosign; it
does not broadcast. From `Admin::CurrenciesController#sweep`, the **Sweep** button
on the currency's row:

```text
https://turfmonster.media/admin/currencies
```

Two preflights run inside that action before anything is queued — the treasury
ATA must exist, and the `op_rev` balance must be positive — which is why step 1
asks the same two questions from the console: a refusal here costs a page load,
but reading the addresses first is what tells you *which* of the two failed and
what to do about it.

**The destination is not a parameter, and passing a signer address fails.** The
controller derives the destination itself with `Solana::Vault#treasury_ata_for`,
and the program then verifies it: `handle_sweep_operator_revenue` requires
`treasury_ata.owner == vault_state.treasury_authority` and raises
`TreasuryAuthorityMismatch` otherwise. There is no parameter that redirects a
sweep to a wallet — not to Alex's, not to a signer's, not to anything. **The
first live attempt tried a signer address and was rejected**; that round trip is
what this paragraph exists to save.

**`amount: 0` means sweep-all**, and the admin path hardcodes it. The handler
reads `amount == 0` as "send the whole available balance", so there is no partial
sweep from the UI. If you need a partial sweep, that is a console call to
`Solana::Vault#build_sweep_operator_revenue` with a raw token amount, and it is
outside this SOP.

**One mint per call.** The instruction is per-currency by design; collecting two
currencies is two sweeps.

### Step 3 — Co-sign, in the Treasury queue

The queued row waits at:

```text
https://turfmonster.media/admin/pending_transactions
```

Alex connects Phantom as the cosigner (`7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr`,
the `MULTISIG_COSIGNER` default) and signs. The server already holds the admin
slot, so on v0.25 that is the second of two signatures and the transaction
broadcasts.

**On v0.26 it will not be enough** — see the timing warning below. The page names
the eligible extra wallets, and the extra slots are part of the transaction
message: they cannot be added after the first wallet has signed. If the queue
tells you a third signature is needed, the row must be rebuilt, not patched.

Note the row's slug and its transaction signature from the page. The live run
recorded `ptx-398`, signature `4VETTK6dy3nZhNNFH8WovW6XGf6u…`.

### Step 4 — Verify from CHAIN, not the UI

The Treasury page will say `confirmed`. That is the app's record of a broadcast,
not a reading of the accounts. Read both balances:

```ruby
vault = Solana::Vault.new
mint  = Solana::Config::USDC_MINT
treasury_ata = vault.treasury_ata_for(mint)
op_rev_ata   = Solana::Keypair.encode_base58(vault.op_rev_ata_pda(mint).first)

[["OP_REV", op_rev_ata], ["TREASURY", treasury_ata]].each do |label, ata|
  bal = vault.client.get_token_account_balance(ata)
  puts "#{label} #{ata} = #{bal&.dig('value', 'uiAmountString').inspect} raw=#{bal&.dig('value', 'amount')}"
end
```

**What a correct result looks like.** Measured on the live run: `op_rev` went
`209 → 0`, treasury went `0 → 210`. The treasury number is the swept 209 **plus
the 1 USDC that created the ATA** in step 1 — so expect the destination to gain
slightly more than the source lost whenever you had to create the account, and do
not read that extra as an accounting error.

`op_rev` at `0` and the treasury unchanged means the sweep went somewhere else,
which on a program that pins its destination should be impossible — treat it as
an escalation, not a retry.

### Step 5 — Hop 2: move it out of the Squads vault

The money is now in the Squads vault, under 3-of-5 control. **This hop is not in
our code.** It is Squads' own web app:

```text
https://app.squads.so/squads/Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm/home
```

**Use that URL. Do not click through from our app.** Squads keys the route on the
**vault PDA** plus `/home`, while `Solana::Config.squads_app_url` interpolates the
**multisig** address and no trailing path — so the link rendered on
`/admin/authorities` and on the admin hub tile **404s**. That was the second lost
round trip of the live run, and it is worse than a plain dead link because the URL
comes from our own code and therefore reads as authoritative. A sibling task fixes
the helper; until it ships, this SOP carries the working link.

Before initiating, confirm the Squads side from chain rather than from the page —
the same discipline as step 4:

```ruby
ms = Solana::Squads.read!
puts "SQUADS #{ms[:address]}"
puts "VAULT_PDA #{ms[:vault_pda]}"
puts "THRESHOLD #{ms[:threshold]} of #{ms[:members].length} members"
ms[:members].each { |m| puts "  MEMBER #{m[:address]} vote=#{m[:can_vote]} execute=#{m[:can_execute]}" }
puts "VOTING_MEMBERS #{ms[:voting_members].length}"
```

Expect `THRESHOLD 3 of 5`. **`VOTING_MEMBERS` is the number that matters**, not
the member count: a member who cannot vote cannot help you reach three.

Then, in Squads: connect a member wallet, initiate a token transfer of the mint
and amount Alex named from the vault to his destination wallet, collect
approvals, and execute. **The transaction reads `Voting N/3`** and does not
execute until `N` is 3.

**Three approvals means three separate wallets, and this SOP cannot supply them.**
Whose they are is Squads membership, which the read above prints. If the other
two approvers are not reachable, the collection stops here with the money safely
in the vault — that is a wait, not a failure.

**The exact button labels in Squads are Squads', and they change.** Nothing in
this repo pins them, so read the page rather than trusting a remembered caption;
what this SOP pins is the URL, the threshold, the direction, and the fact that
nothing local participates.

### Step 6 — Report

Report both hops separately, and say which one you got to. Give:

- the mint, and the amount swept on hop 1, read from chain in step 4;
- the `PendingTransaction` slug and the hop-1 signature;
- the treasury balance now sitting in the Squads vault;
- for hop 2: initiated / `Voting N/3` / executed, and the destination wallet;
- if you stopped after hop 1, **say so in those words** — "swept to the treasury,
  not yet withdrawn" — because "collected" will be read as "in his wallet".

## What it refuses, and what each refusal means

| Refusal | Where it comes from | What it means | Remedy |
|---|---|---|---|
| `Treasury ATA does not exist for this mint (create it first)` | the `sweep` action's preflight | the destination account has never been created, and no admin action creates one | Step 1's remedy: send 1 USDC from Phantom to the **treasury authority** address; it is swept back |
| `Nothing to sweep — operator revenue ATA balance is 0` | the `sweep` action's preflight | there is no revenue to collect | Nothing. Confirm you are on the right cluster and the right mint before doubting it |
| `EmptyRevenueAccount` | the program, `handle_sweep_operator_revenue` | same condition, reached on chain — the balance emptied between preflight and broadcast | Re-read both balances (step 4). Someone else's sweep may already have landed |
| `TreasuryAuthorityMismatch` | the program | the destination ATA is not owned by `vault_state.treasury_authority` | **Do not pick a different address.** The destination is pinned; a mismatch means you built the transaction by hand with the wrong ATA, or `treasury_authority` is not what you assumed. Re-read `VaultState` |
| `Unauthorized` | the program's multisig constraint | the signers are not two distinct members of the VaultState set | Cosign as a real member; the three addresses are in the table above |
| `InsufficientSigners` (6046) | the program, on v0.26 | the action's threshold rose to 3 and the transaction carries 2 | Rebuild the row with an extra cosigner slot. See the timing warning |
| `Solana::Vault::ThresholdUnreachableError` | Rails, locally | a server-signed path cannot reach the threshold, refused before broadcast | The same remedy, caught before a fee was spent — this is the good outcome |
| a 404 on the Squads link | `Solana::Config.squads_app_url` | the helper interpolates the multisig, not the vault PDA, and omits `/home` | Use the URL in step 5 |

## ⚠️ turf-vault v0.26 raises the sweep from 2 signers to 3

**Today mainnet and devnet both run v0.25.0, and `sweep_operator_revenue` is
2-of-3.** v0.26 makes signature thresholds DATA (`GovernanceConfig`) and raises
this action to **3**, alongside `settle_contest`, `cancel_contest`,
`register_currency`, `deactivate_currency` and `unpause`. The table is in
`turf-monster/docs/SOLANA.md` under *"v0.26 signature thresholds"*; the same
change is noted in `Solana::Vault` above `build_sweep_operator_revenue`.

**v0.26 is on `accepted` and NOT deployed.** So the signer count can change under
a reader of this SOP without a word of this file changing. What that costs you:

- the server still contributes **one** signature; the browser must come back with
  **two** instead of one;
- the extra signature rides as a leading `remaining_accounts` meta with
  `is_signer: true`, and **the slots are part of the message** — they cannot be
  added once the first wallet has signed, so a 2-signature row must be rebuilt;
- **the threshold is retunable by one `set_action_threshold` transaction**, so
  after v0.26 the live number is not even pinned to a release.

**Read the count, do not remember it.** Before a sweep on a cluster you have not
swept on recently, check which build it runs — `turf-vault/docs/CURRENT_DEPLOYMENT.md`
carries the method (an instruction-set probe against a program dump, cross-checked
against `EXPECTED_IDL_HASH`) and states plainly that the committed IDL is not
evidence of what is live.

## What this does NOT cover

- **Building hop 2 in our app.** It does not exist and this SOP does not add it.
  If Alex wants it, that is a task, and a treasury-risk one.
- **Creating the treasury ATA from the app.** Same answer; the Phantom transfer in
  step 1 is the remedy, not a workaround to productise mid-run.
- **Partial sweeps from the UI.** The admin path is sweep-all.
- **Non-USDC currencies**, beyond "one mint per call". A currency must be
  registered in `VaultState.accepted_currencies` before it has an `op_rev` ATA at
  all; registering one is `/admin/currencies` → register, a different act.
- **Changing Squads membership or thresholds.** Squads' own UI, and a decision
  about custody rather than about collection.
- **A paused program.** `pause` blocks the money-moving paths; unpausing is its own
  2-of-3 (3 from v0.26) act.
- **Anything after the money reaches the personal wallet.** Tax and accounting
  treatment of operator revenue is outside this SOP.

## Escalate rather than improvise when

- `op_rev` reads `0` after a sweep and the **treasury did not gain the balance**;
- `treasury_authority` is not the Squads vault PDA you expected for that cluster;
- the Squads read returns fewer than three **voting** members, or a threshold the
  membership cannot reach;
- a refusal repeats after its remedy;
- a sweep broadcast and the Treasury row cannot be reconciled to a signature;
- anyone asks you to sweep to an address that is not the pinned treasury ATA.

For a blocker that stops the run, run
[`address-blocker`](../../../modules/address-blocker.md).

## Background — not needed to execute

**Why the destination is pinned at all.** A parameterised destination would make
the 2-of-3 that guards a sweep the only thing standing between two signers and an
arbitrary wallet. Pinning it to `vault_state.treasury_authority` means the most a
compromised pair can do is move revenue into a 3-of-5 vault — which is to say,
nowhere useful. The two hops are the custody design, not an inconvenience in it.

**Why hop 2 is deliberately absent from our code.** Squads ships its own web UI
for exactly this, and turf-monster declines to reimplement it; `/admin/authorities`
links out instead. A Squads transfer built in our app would put the withdrawal
path behind our own auth, which is the opposite of what a 3-of-5 vault is for.

**Where the accounts come from.** `op_rev` is a PDA at seeds `[b"op_rev", mint]`
with the `VaultState` PDA as its authority, derived by
`Solana::Vault#op_rev_ata_pda`; the treasury ATA is the ordinary associated token
account of `treasury_authority` for that mint, derived by
`Solana::Vault#treasury_ata_for`. Neither is stored in Rails — both are computed
from the mint and the live `VaultState`, which is why every read in this SOP
starts there.

**The forfeit case is the mirror of this one.** An entrant who withdraws forfeits
a fee that is already in `op_rev`, which is why that SOP needs no transfer at all:
[`entry-forfeit`](entry-forfeit.md). The contest lifecycle these fees arrive
through is rehearsed end to end on devnet by
[`contest-rehearsal`](contest-rehearsal.md).
