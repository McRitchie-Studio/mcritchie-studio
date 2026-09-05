# QA Contest Rehearsal

## Status: Active

This is Turf Monster's `contest-rehearsal` SOP. It runs one whole contest
lifecycle on QA — create, enter, play, settle, close — against **devnet**, with
real wallets, real ESPN scores and a real on-chain payout, so the mechanics can
be watched end to end before the same path runs on mainnet with real money.

It is Turf Monster's because every judgment it asks for is a contest judgment:
whether the board looks right, whether the standings moved the way the games
did, whether the payout matches the leaderboard.

**It ships nothing.** It writes only to `turf-monster-qa` and the devnet
program. It never touches `release`, `main`, production, or the mainnet vault.

## Why it exists

The steps this rehearses — entry, grading, settlement, payout — are the ones
nothing else routinely covers, and they are the ones that move money. The first
production World Cup contest sat un-graded for three months, and a second was
graded in the database while its on-chain settlement was never co-signed, so its
winners held a credit and no USDC. Both were found by reading production, not by
a test.

## Entry — WHICH environment, stated by the guard

Run from the rehearsal worktree (the driver is a local command that drives the
deployed QA app over HTTP):

```bash
cd /Users/alex/projects/turf-monster
bin/qa-contest-rehearsal <step>
```

**You do not choose the environment; the guard does.** `NetworkGuard` runs
before any key is loaded and refuses anything but `turf-monster-qa` running the
devnet program, checking BOTH the network and the program id. That is not
ceremony: the co-signing key is Mason's, and Mason is a signer on the MAINNET
vault too.

## The cast

Three wallets whose keys are filed in 1Password `studio-agents`:

| Slug | 1Password item | Plays as |
|---|---|---|
| `mason` | `agent.mason.solana` | mason-3 |
| `mack` | `agent.mack.solana` | mack-4 |
| `turf` | `phantom.turf` | regal-parsley-167 |

Two exclusions, and neither is a preference:

- **Alex cannot play.** `agent.alex.solana` IS the Alex Bot wallet — the fee
  payer and contest creator. When the player is also the fee payer the
  transaction needs one signature slot, not two, and `prepare_entry` refuses.
- **turf-5 cannot play.** Its username is the reserved on-chain prefix `turf`
  and it has no `UserAccount`, so the program refuses to register it. It stays
  on as the admin HTTP actor, where no `UserAccount` is needed.

## The steps

Each step prints the URLs it just made relevant. **Open them** — the driver runs
in a terminal but the thing being rehearsed is a web app.

### ⛔ ONE STEP PER TURN — this is the whole point of the split

**If you are an agent running this SOP: run ONE step, hand the URLs to Mr.
McRitchie, and STOP. Do not run the next step until he has answered.** He is
not reading a log afterwards; he is watching a board while it moves, and a run
that does all five in one turn gives him nothing to watch. Ending your turn IS
the step — a message that reports the step and then keeps going has not stopped.

The driver prints a `── STOP ──` block at the end of every step naming what he
is confirming and what to run next. **When you see it, hand back.** It is there
because this instruction, living only in this file, was read once at the top of
a run and lost to momentum: on 2026-09-04 an agent ran create through close in a
single turn and Mr. McRitchie never saw a board mid-flight. Nothing failed — the
SOP simply never said to stop.

Step 4 with `--cosign link` is the one that cannot be waved through. The settle
is 2-of-3 and the server has signed only its own half, so **a run that continues
past it closes a contest that never paid.**

### Step 1 — create the contest

```bash
bin/qa-contest-rehearsal create
```

Creates a standard-tier contest, funded on-chain from the admin wallet ($500
pool, five paid ranks), and time-shifts the fixture forward so the board is
pickable. Prints the slug.

```text
Contest:      https://qa.turfmonster.media/contests/<slug>
Live Board:   https://qa.turfmonster.media/contests/<slug>/live
```

**Look at the contest page.** It should read `$500 Prizes`, `$19 Entry`,
`0/29 Entries`, and show the matchup cards unlocked.

→ **Hand back now.** Wait for his go-ahead before step 2.

### Step 2 — enter the cast

```bash
bin/qa-contest-rehearsal enter                    # all three, the default
bin/qa-contest-rehearsal enter --cast mason,mack  # or a subset
```

Each player signs in as a wallet (nonce → message → signature → verify), clears
the age gate, builds a six-pick cart, and confirms an on-chain entry. Every
signature comes from 1Password; no browser is involved.

```text
Contest:      https://qa.turfmonster.media/contests/<slug>
```

**Look at the contest page.** Entries should read `3/29`, and each player should
appear on the leaderboard at 0.

→ **Hand back now.** Wait for his go-ahead before step 3.

### Step 3 — play the preseason

```bash
bin/qa-contest-rehearsal play --pace 4
```

Locks the contest (a contest locks at kickoff, THEN the games play), clears the
board, zeroes the leaderboard, and replays a real preseason week **one scoring
play at a time**.

The lock used to be what made the live board reachable at all — `#live`
redirected unless the contest was locked and unsettled. It no longer does; that
page renders in every state now, so the lock here is about ordering the
rehearsal the way a real contest runs, not about unlocking a URL.

The plays are real: the ESPN poller has already written them as `Goal` rows, and
this re-lays them on a clock. Each one fires the same chain the live feed fires —
score refresh, contest re-score, both broadcasts.

```text
Live Board:   https://qa.turfmonster.media/contests/<slug>/live
League Board: https://qa.turfmonster.media/live
```

**Watch the live board.** This is the step worth watching: the scores build from
zero, games flip to FINAL as their last play lands, and the standings reshuffle.
At `--pace 4` a 129-play week takes about nine minutes.

→ **Hand back now.** Wait for his go-ahead before step 4.

### Step 4 — conclude and pay

```bash
bin/qa-contest-rehearsal conclude --cosign link     # you sign in Phantom
bin/qa-contest-rehearsal conclude --cosign agent    # unattended, Mason's key
```

Grades the contest, ranks the entries, and builds the 2-of-3 settle transaction.
The server has already signed as Alex Bot; the second signature is yours.

```text
Magic Link:   https://qa.turfmonster.media/l/<token>   → /admin/pending_transactions
Contest:      https://qa.turfmonster.media/contests/<slug>
```

**On the Treasury page: Rebuild first, then Co-sign.** The transaction carries a
blockhash that expires in about 90 seconds, so the one built a minute ago will
not send. Rebuild is the step people skip.

**Check the arithmetic afterwards.** The prize pool should fall by exactly the
sum paid, and each winner's balance should rise by exactly their rank's payout.
That subtraction is the proof the payout landed — not the transaction signature,
which only proves something was broadcast.

→ **Hand back now.** Which halt this is depends on the flag you ran, and step 4
has three exits, not two:

| Exit | Who acts next |
|---|---|
| `--cosign link` | **He does.** He signs in Phantom; you cannot do this half |
| `--cosign agent` | Nobody — Mason's key already signed it, unattended |
| nobody was owed | Nobody — the contest graded with no winner to pay |

All three stop. On the two unattended exits he is confirming the arithmetic
rather than performing the signature, and on `--cosign link` **nothing can
proceed until he signs**: the settle is 2-of-3 with only the server's half
signed, so continuing past it closes a contest that never paid.

### Step 5 — close

```bash
bin/qa-contest-rehearsal close
```

Reclaims the contest's rent. A run that ends here is asset-positive.

```text
Contest:      https://qa.turfmonster.media/contests/<slug>
```

**Look at the contest page one last time.** It should read settled, with the
final standings and each winner's payout beside their rank. That is the same
page the operator would open to answer "did this contest actually pay out?" —
so it is the one worth leaving open.

→ **Hand back.** The rehearsal is done; report what he should see.

## What this does NOT cover

Stated so nobody reads a green rehearsal as more than it is:

- **The browser create path.** Step 1 uses the server-funded console path, not
  the Phantom create flow.
- **The browser entry path.** Step 2 drives the same HTTP endpoints a browser
  does and runs every server-side gate, but no page is rendered and no wallet
  extension is exercised.
- **Mainnet.** Every guard in this act exists to keep it off mainnet.

## Background — not needed to execute

Design and mechanics of the driver live with the code in
`turf-monster/lib/turf_monster/qa_rehearsal/`. The scoring pipeline it borrows
is [`live-score-watch`](live-score-watch.md).
