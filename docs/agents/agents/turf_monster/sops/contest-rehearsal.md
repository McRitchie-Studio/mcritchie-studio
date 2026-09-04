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

### Step 2 — enter the cast

```bash
bin/qa-contest-rehearsal enter            # or --cast mason,mack
```

Each player signs in as a wallet (nonce → message → signature → verify), clears
the age gate, builds a six-pick cart, and confirms an on-chain entry. Every
signature comes from 1Password; no browser is involved.

```text
Contest:      https://qa.turfmonster.media/contests/<slug>
```

**Look at the contest page.** Entries should read `3/29`, and each player should
appear on the leaderboard at 0.

### Step 3 — play the preseason

```bash
bin/qa-contest-rehearsal play --pace 4
```

Locks the contest (a contest locks at kickoff, THEN the games play — this is
also what makes the live board render), clears the board, zeroes the
leaderboard, and replays a real preseason week **one scoring play at a time**.

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

### Step 5 — close

```bash
bin/qa-contest-rehearsal close
```

Reclaims the contest's rent. A run that ends here is asset-positive.

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
