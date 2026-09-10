# Entry Forfeit

## Status: Active

This is Turf Monster's `entry-forfeit` SOP. It withdraws **one entrant from one
contest at that entrant's own request**, forfeiting their entry fee. It is the
withdraw-and-forfeit case, and only that case.

It is **not** a refund, **not** an account deletion, and **not** a moderation
tool. If the entrant wants their money back, stop — nothing in this SOP does
that, and the section **What you cannot do** explains why the chain cannot
either.

It is Turf Monster's because every judgment it asks for is a contest judgment:
whether the contest has graded yet, whether the seat can be resold, and what the
fill counter should read when you are done.

## Why it exists

This touches a live money contest, and the two obvious moves are both wrong:

- **Deleting the entry row** destroys the record of a paid on-chain entry while
  the entry PDA lives on forever. The DB and the chain disagree from then on.
- **Refunding the fee** cannot be done at all. There is no instruction for it.

The correct move is one status flip, and it has a hard deadline. Written after a
live run on `turf-monster-mainnet` on 2026-09-09 that took a contest from 8/9 to
7/9.

## What "forfeit" already means on-chain — read this before touching anything

The entrant's money is already out of their wallet, and it was **never in the
prize pool**. Three facts, and together they mean a forfeit needs no transfer,
no signature, and no multisig:

| Fact | Where |
|------|-------|
| The entry fee transfers **user ATA → `op_rev` ATA** at entry time | `turf-vault/programs/turf_vault/src/instructions/enter_contest.rs` — the SPL transfer in `handle_enter_contest` |
| It never enters the prize pool | `settle_contest.rs` header: *"Entry fees are NOT included anymore — they sit in op_rev ATAs, separate from the prize pool"* |
| Payouts are a **fixed schedule per format**, not a share of fees | `Contest::FORMATS` in `turf-monster/app/models/contest.rb` |

So: the fee is already operator revenue, and the other entrants' prizes do not
move when one entrant leaves. Forfeiting costs the house nothing and the field
nothing. **All you are doing is keeping the leaver out of the grading.**

## What you cannot do

Say this plainly to whoever asked, because the request often arrives as "refund
and remove":

- **No per-entry refund exists on-chain.** `turf-vault` has no cancel-entry,
  refund-entry, or withdraw-entry instruction. The full instruction set is
  initialize, update_signers, register/deactivate_currency, pause/unpause,
  create/admin_create_user_account, set/admin_set_username, create_season,
  create_contest, set_contest_lock_time, set_contest_conclusion_time,
  settle_contest, cancel_contest, close_contest, enter_contest,
  enter_contest_with_token, mint_entry_token, burn_entry_token, grant_seeds,
  sweep_operator_revenue.
- **The entry PDA is permanent.** `EntryStatus` is `Active / Won / Lost` only
  (`turf-vault/programs/turf_vault/src/state.rs`) — there is no Forfeited or
  Refunded. The entry stays `Active` on-chain, as every non-winner does, because
  `settle_contest` only writes the entries in its winners vec.
- **`cancel_contest` is not a per-user tool.** It refunds the whole prize pool
  to the **creator**, works only from Open or Locked, and explicitly leaves entry
  fees as platform revenue.
- **Never `entry.destroy`.** It orphans a paid PDA and erases the paid-entry
  record. There is no case in this SOP where destroying the row is correct.
- **Custodial does not change any of the above.** A managed-wallet entrant
  (`web2_solana_address` set, `self_custodied_at` nil) means the server holds
  their key — it does not conjure an instruction that does not exist.

## The deadline — before `Contest#grade!`

This is the whole gate. `grade!` is what makes the flip meaningful:

| Before `grade!` | After `grade!` |
|-----------------|----------------|
| `grade!` ranks only `status: [:active, :complete]`, so an abandoned entry gets no rank and no `payout_cents` | The entry is already `complete` with a rank, a `payout_cents`, and a payout `TransactionLog` credit |
| `settle_onchain!` builds its winners from `entries.complete.where("payout_cents > 0")`, so the entry is not in the settlement | The on-chain settle may already have paid out |
| Fully reversible with one line | Not reversible by this SOP — escalate to Mr. McRitchie |

Check `contest.status` first, every time. `settled` means you are too late.

## Entry — what you need in hand

Ask for, and confirm, all four before you run anything:

1. **The entrant asked in writing.** This SOP forfeits real money at the
   entrant's request. Nothing in the app records *why* — there is no forfeit
   reason column and no audit row — so keep their request outside the app
   (email is fine). Do not run this on a third-hand verbal report.
2. **Which entrant** — resolve to a `User` id. Names repeat; emails do not.
3. **Which contest** — one entrant can hold entries in several.
4. **Which entry** — an entrant may hold more than one entry in the same
   contest. Forfeit the one they named, not "their entry".

Everything below runs against production:

```bash
heroku run --no-tty -a turf-monster-mainnet -- bin/rails runner "<script>"
```

## ⛔ `heroku run` stdout can vanish — this shapes every step

A one-off dyno sometimes delivers **no stdout at all** to your local pipe even
though the script ran fine. Empty output is not evidence that nothing happened.
Three consequences, and they are why the steps are split the way they are:

- **Capture the backup in step 1**, from a read-only run you already have in
  hand. The mutator's own printed backup can evaporate.
- **Make the mutation self-guarding and idempotent** (step 2) so a blind re-run
  is safe.
- **Verify in a separate read** (step 3). Never trust the mutator's own stdout.

## The steps

### Step 1 — read, and capture the backup

Resolve the entrant and print every entry they hold, with each contest's state.
This output **is** your backup — keep it in the session before you write:

```ruby
u = User.find_by(email: "<entrant email>")
abort("no such user") if u.nil?
puts "USER #{u.id} #{u.slug} #{u.email} web2=#{u.web2_solana_address.inspect} self_custodied=#{u.self_custodied_at.inspect}"
u.entries.includes(:contest).order(:id).each do |e|
  c = e.contest
  puts "ENTRY id=#{e.id} slug=#{e.slug} status=#{e.status} num=#{e.entry_number.inspect} rank=#{e.rank.inspect} payout=#{e.payout_cents} tx=#{e.onchain_tx_signature.inspect}"
  puts "  CONTEST id=#{c.id} slug=#{c.slug} status=#{c.status} max=#{c.max_entries} onchain=#{c.onchain?}"
  puts "  FILL active+complete=#{c.entries.where(status: %w[active complete]).count}/#{c.max_entries} by_status=#{c.entries.group(:status).count}"
end
```

**Stop here unless all three hold.** The contest is not `settled`; the target
entry is `active`; the entry id belongs to the entrant who asked.

### Step 2 — write, guarded

Fill in the three identity constants at the top. Every guard aborts rather than
guesses, and a re-run after a vanished stdout is a no-op:

```ruby
ENTRY_ID  = 0                       # from step 1
USER_ID   = 0                       # from step 1
EMAIL     = "<entrant email>"       # from step 1

e = Entry.find_by(id: ENTRY_ID)
abort("ABORT: entry #{ENTRY_ID} missing") if e.nil?
abort("ABORT: user mismatch #{e.user_id}") unless e.user_id == USER_ID
abort("ABORT: email mismatch #{e.user.email}") unless e.user.email == EMAIL
c = e.contest
abort("ABORT: contest already settled") if c.settled?
if e.abandoned?
  puts "NOOP: already abandoned"
else
  abort("ABORT: unexpected status #{e.status}") unless e.active?
  puts "BEFORE status=#{e.status} num=#{e.entry_number.inspect} rank=#{e.rank.inspect} payout=#{e.payout_cents} tx=#{e.onchain_tx_signature}"
  e.update!(status: :abandoned)
  puts "WROTE status=#{e.reload.status}"
end
puts "FILL_NOW=#{c.entries.where(status: %w[active complete]).count}/#{c.max_entries}"
```

`abandoned` is the right status and it has no side effects here:
`Entry#release_slot_if_abandoned` clears `entry_number` **only** when
`onchain_tx_signature` is blank, so a paid entry keeps the slot it was created
under and nothing renumbers.

### Step 3 — verify in a separate read

Confirm the row, the fill, and — because the two disagree by design — the
on-chain counter:

```ruby
e = Entry.find(<ENTRY_ID>); c = e.contest
puts "VERIFY entry=#{e.id} user=#{e.user.email} status=#{e.status} num=#{e.entry_number.inspect} rank=#{e.rank.inspect} payout=#{e.payout_cents} tx_intact=#{e.onchain_tx_signature.present?}"
puts "VERIFY contest=#{c.slug} status=#{c.status} FILL=#{c.entries.where(status: %w[active complete]).count}/#{c.max_entries} by_status=#{c.entries.group(:status).count}"
v = Solana::Vault.new; pda = v.contest_pda(c.slug); addr = pda.is_a?(Array) ? pda.first : pda
b58 = Solana::Keypair.encode_base58(addr) rescue addr.to_s
info = Solana::Client.new.get_account_info(b58)
raw  = info.is_a?(Hash) ? (info["data"] || info.dig("value", "data")) : nil
raw  = raw.first if raw.is_a?(Array)
bytes = Base64.decode64(raw.to_s)
puts "VERIFY onchain pda=#{b58} max=#{bytes[372, 4].unpack1('V')} current_entries=#{bytes[376, 4].unpack1('V')}"
```

Byte offsets 372 and 376 are `max_entries` and `current_entries` in the Anchor
`Contest` account (8 discriminator + 32 contest_id + 32 admin + 32 creator +
4 season_id + 8 prize_pool + 128 entry_fee_by_currency + 128 entry_fees). If
`state.rs` gains a field ahead of them, recompute rather than trusting these.

**Expect the two counters to disagree by exactly the entries you have
forfeited.** That is not a bug you introduced; it is the next section.

### Step 4 — report, and carry the warning

Report the before/after fill, and state the seat gap explicitly. It is the one
fact the operator cannot see on the board.

## ⚠️ The seat does not come back on-chain

`contest.current_entries` is set to `0` at creation and only ever incremented on
entry (`enter_contest.rs`, `enter_contest_with_token.rs`). **Nothing decrements
it** — there is no instruction that could. But Rails' fill check counts only
`[:active, :complete]` (`Entry#assert_enterable!`). So after a forfeit:

```text
Rails:     7/9   → advertises 2 open seats
on-chain:  8/9   → will accept exactly 1 more entry
```

The consequences, in order of who gets hurt:

- **One replacement entrant too many will fail.** Their `enter_contest` is
  rejected by the `current_entries < max_entries` constraint with `ContestFull`.
  The transaction fails atomically, so **no money is lost** — they see an error.
- **Do not promise the seat.** If someone is waiting for a spot, count from the
  on-chain number in step 3, never from the board.
- **The leaver cannot re-enter that slot.** `Entry#assign_onchain_entry_number!`
  probes the chain, not the DB, precisely because PDAs outlive rows — their old
  slot still reads as taken, so a change of heart consumes a new slot against
  their per-user cap.

The gap closes on its own at the contest's lock time, after which the chain
refuses new entries regardless.

## Reversal

While the contest is unsettled, the flip is fully reversible — nothing on-chain
was touched:

```ruby
e = Entry.find(<ENTRY_ID>)
abort("ABORT: contest settled") if e.contest.settled?
e.update!(status: :active)
puts "REVERTED status=#{e.reload.status}"
```

Then re-run step 3. After `grade!` there is no reversal in this SOP.

## Making the entrant whole later

If the call changes and you want to compensate them, the lever is a **free entry
token**, not cash: `/admin/free_entries` → mint (`Admin::FreeEntriesController`).
That is the channel `cancel_contest` itself designates for entrant
compensation — *"Operator handles entrant compensation off-chain via
`mint_entry_token` goodwill credits."* It works for custodial and self-custodied
entrants alike, and it costs a seat rather than a payout.

## What this does NOT cover

Stated so nobody stretches this SOP past its edges:

- **Refunds.** No path, on-chain or off. Do not improvise one.
- **Removing a user account.** Turf Monster has no account deletion; the
  closest lever is the account freeze (`User#freeze_for_payment_risk!` /
  `#unfreeze!`), which blocks money-moving actions and is a different decision
  with a different trigger.
- **Cancelling a whole contest.** That is `cancel_contest`, 2-of-3 multisig,
  and it refunds the pool to the creator — a separate act, not a loop over this
  one.
- **A settled contest.** Escalate to Mr. McRitchie.
- **Any UI.** There is no admin button for this and this SOP does not add one.
  Every step is the production console.

## Background — not needed to execute

The contest lifecycle these entries sit inside is rehearsed end to end on QA by
[`contest-rehearsal`](contest-rehearsal.md). The grading and settlement code
this SOP steps around is `Contest#grade!` and `Contest#settle_onchain!` in
`turf-monster/app/models/contest.rb`.
