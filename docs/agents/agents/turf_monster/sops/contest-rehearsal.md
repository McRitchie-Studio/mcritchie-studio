# QA Contest Rehearsal
<!-- registry: QA devnet lifecycle -->

## Status: Active

This is Turf Monster's `contest-rehearsal` SOP. It seeds the parked roster once
per QA database, then runs one whole contest lifecycle on QA — create, enter,
play, settle, close — against **devnet**, with
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

Run from a turf-monster checkout. The driver is a local command that drives the
deployed QA app: it runs scripts on the QA dyno through `heroku run`, and the
players enter over HTTP.

```bash
cd /Users/alex/projects/turf-monster
bin/qa-contest-rehearsal <step>
```

**You do not choose the environment; the guard does.** `NetworkGuard` runs
before any key is loaded and refuses anything but `turf-monster-qa` running the
devnet program, checking BOTH the network and the program id. That is not
ceremony: the cast's keys are real wallets.

**Agents co-sign on devnet.** Devnet runs turf-vault v0.26 with `settle_contest`
at 2 signatures (card `devnet-v026-upgrade`, 2026-10-12). The default
`conclude --cosign agent` settles with the QA server key (`2eGs…`) plus the
devnet-only agent key Mack (`8UwJ…` since 2026-10-24), and the v0.26 lock and close take the same
two, so the whole run needs **no human tap**. The rehearsal refuses any key it
loads, player or co-signer, that holds MAINNET authority (a mainnet `VaultState`
signer, seated or incoming, or a mainnet Squads member), even on devnet
(turf-monster `MainnetSignerFence`, `config/mainnet_vault_signers.yml`), and it
refuses Mr. McRitchie's personal wallets the same way (list `personal`: `DKbv…`,
filed as `solana.turf.alex`). That is why Mason (`CytJ…`, a mainnet signer until it was retired on 2026-10-14) no
longer plays.
`--cosign link` still exists for a run Mr. McRitchie wants to sign himself in
Phantom (`7ZDJ…` is no longer a devnet signer, so that path needs a wallet the
devnet `VaultState` seats, such as `9gAC…`).

What each step needs to be true on QA, the message each one stops with, and the
operator's co-signing clicks are in `turf-monster/docs/qa-contest-rehearsal.md`.
This SOP is the order and the hand-backs; that page is the detail.

## The cast

Two wallets are filed in 1Password `studio-agents`, and both PLAY. Mack also
co-signs:

| Slug | 1Password item | Plays as |
|---|---|---|
| `mack` | `solana.mack.agent` | mack-4 |
| `turf` | `solana.turf.agent` | regal-parsley |

> **There is no admin actor.** No agent-readable wallet signs in as an admin
> account, so `KeyStore::ITEMS` files none: the house account holds no wallet,
> and `solana.turf.admin` is rotated out and archived. `--cosign agent` needs no
> admin session: it confirms on the dyno through `heroku run`.

Two exclusions, and neither is a preference:

- **The server key cannot play.** QA's server key (`2eGs…`,
  `solana.turf.system.devnet`, `SOLANA_ADMIN_KEY` on the dyno) is the fee payer
  and contest creator, and when the player is also the fee payer the
  transaction needs one signature slot, not two — `prepare_entry` refuses.
  Production's key (`4S39…`, `solana.turf.server`, since 2026-10-14; the retired
  Alex `8K81…` before it) is in no devnet signer set and is not filed for the
  rehearsal.
- **turf-5 cannot play.** Its username is the reserved on-chain prefix `turf`
  and it has no `UserAccount`, so the program refuses to register it.

## The steps

Each step from `create` on prints the URLs it just made relevant. **Open them** — the driver runs
in a terminal but the thing being rehearsed is a web app.

### Two ways to run it: unattended (the gauntlet) or watched

**Unattended, the default for an agent.** The devnet gauntlet is agent-run
(Alex McRitchie, 2026-10-12): run every step in one turn with `--cosign agent`, step 3 as
a bare `bin/qa-contest-rehearsal play` (no `--pace`), and at each `── STOP ──`
block check the thing it names yourself and record it, rather than handing
back. The whole gauntlet takes about 9 minutes (measured on 2026-10-14, after
rel-20261014-a49a7f: seed 25 s, create 48 s, enter 16 s, play 4 min, conclude
2 min 20 s, close 75 s); each step prints its own `elapsed:` line. What to
check, per step: `seed` names every parked username;
`create` reads pool $500, on-chain yes; `enter` reports every cast member
entered; `play` ends `replay: caught up — 246 plays on the board, 32 games
final, …` (it exits non-zero on `replay: CATCH-UP FAILED`); `conclude` prints
`confirmed` with `onchain_settled: true`; then **check the arithmetic** from the
settle transaction's own token balances (the prize escrow, owned by the
`VaultState` PDA, falls by exactly the sum paid; each winner's USDC rises by
exactly their rank's payout); `close` returns a signature. Any step that stops
or answers otherwise ends the run: report it.

**Watched, when Alex McRitchie asks to watch.** Then the old rule holds: run ONE step,
hand him the URLs, and STOP until he answers.

The driver prints a `── STOP ──` block at the end of every step naming what he
is confirming and what to run next. **In a watched run, when you see it, hand
back; in an unattended run, check that thing yourself and record it.** It is there
because this instruction, living only in this file, was read once at the top of
a run and lost to momentum: on 2026-09-04 an agent ran create through close in a
single turn and Alex McRitchie never saw a board mid-flight. Nothing failed — the
SOP simply never said to stop.

Step 4 with `--cosign link` is the one that cannot be waved through: the server
has signed only its own half, so **a run that continues past an unsigned link
closes a contest that never paid.** `close` refuses an unsettled contest, but do
not lean on that.

### Step 0 — seed the parked roster (once per QA database)

```bash
bin/qa-contest-rehearsal seed
```

Runs the app's own roster seed (`db/seeds/users.rb`) on QA in its proven-only
form. It writes the parked roster rows and their wallets, and demotes retired
seats; it writes no other row. Step 1 needs the creator row it writes. A re-run
changes nothing, so a database that has been seeded skips this step.

It adopts an existing row only when it can prove it. It stops before any write,
and names each row by username, when a row it would adopt:

- holds a parked roster address unverified beside another credential (a wallet,
  a Google link or an API key), or
- matches a roster identity by username alone, with no row on that identity's
  address or wallet.

An operator resolves each row by hand on QA, then runs `seed` again.
`heroku run --app turf-monster-qa -- bin/rails users:parked_role_audit` lists
the unproven holders on QA.

**Look at the roster line.** It should name every parked username.

→ **Watched: hand back now** and wait for his go-ahead; unattended: check it and go on to step 1.

### Step 1 — create the contest

```bash
bin/qa-contest-rehearsal create
```

Reads what it needs before it writes anything, and stops if the creator row is
missing (run step 0), the slate is missing, or the devnet `VaultState` cannot be
read. It also stops when the server key (`SOLANA_ADMIN_KEY` on the dyno) is not
a signer in the devnet `VaultState`. It prints the key the server signs as and
the co-signer the settle will name, and warns, without stopping, when the server
key is missing from the app's `SOLANA_MULTISIG_SIGNERS`.

Then it creates a standard-tier contest ($500 pool, four paid ranks: $300, $100, $50, $50), funded
on-chain from the server key's devnet USDC. When that key holds less than the
pool it mints more, which works only while the server key is the devnet test
mint's authority. Otherwise it stops before any contest is created: fund the
key's USDC account, or move the mint authority to it. It also time-shifts the
fixture forward so the board is pickable, and prints the slug.

```text
Contest:      https://qa.turfmonster.media/contests/<slug>
Live Board:   https://qa.turfmonster.media/contests/<slug>/live
```

**Look at the contest page.** It should read `$500 Prizes`, `$19 Entry`,
`0/29 Entries`, and show the matchup cards unlocked.

→ **Watched: hand back now** and wait for his go-ahead; unattended: check it and go on to step 2.

### Step 2 — enter the cast

```bash
bin/qa-contest-rehearsal enter                    # the whole cast, the default
bin/qa-contest-rehearsal enter --cast mack        # or a subset
```

Each player signs in as a wallet (nonce → message → signature → verify), clears
the age gate, builds a six-pick cart, and confirms an on-chain entry. Every
signature comes from 1Password; no browser is involved.

```text
Contest:      https://qa.turfmonster.media/contests/<slug>
```

**Look at the contest page.** Entries should read `2/29` (the step prints the
count it expects), and each player should appear on the leaderboard at 0.

→ **Watched: hand back now** and wait for his go-ahead; unattended: check it and go on to step 3.

### Step 3 — play the preseason

```bash
bin/qa-contest-rehearsal play              # unattended: every play, back to back
bin/qa-contest-rehearsal play --pace 4     # watched: the same replay, 4 s apart
```

Locks the contest (a contest locks at kickoff, THEN the games play), clears the
board, zeroes the leaderboard, and replays a real preseason week **one scoring
play at a time**. The pace is only for eyes: both forms re-lay the same plays
in the same order through the same code, and both end with the catch-up check
below. `--pace` takes fractions (`0.5`); `--pace 0` is refused, because it used
to mean poll-only. Poll-only, which writes the week in one burst and skips the
per-play chain, has to be asked for by name: `--no-replay`. It is a poller
check, never a gauntlet.

The lock used to be what made the live board reachable at all — `#live`
redirected unless the contest was locked and unsettled. It no longer does; that
page renders in every state now, so the lock here is about ordering the
rehearsal the way a real contest runs, not about unlocking a URL.

The plays are real: the ESPN poller has already written them as `Goal` rows, and
this re-lays them on a clock. Each one fires the same chain the live feed fires —
score refresh, contest re-score, both broadcasts.

**What the replay keeps, at any pace (the fidelity criteria):**

- every captured play is re-created through `Goal.create!`, so its callbacks,
  the contest re-score and both live broadcasts run as they do for the feed;
- plays go in kickoff-then-game-clock order, so simultaneous games interleave;
- each game concludes (`Game#conclude!`) right after its own last play;
- **the catch-up check** runs before the step may hand on: every play is back
  on the slate, every game reads completed, each game's score is the sum of its
  plays and each matchup carries it, every entry in every open contest on the
  slate scores what a fresh recompute gives, and nothing was rescued into
  `ErrorLog` during the replay. Any miss prints `replay: CATCH-UP FAILED — …`
  and stops the step. The chain is synchronous today, so it never waits; it
  proves rather than assumes that `conclude` grades a caught-up board.

```text
Live Board:   https://qa.turfmonster.media/contests/<slug>/live
League Board: https://qa.turfmonster.media/live
```

**Watch the live board.** This is the step worth watching: the scores build from
zero, games flip to FINAL as their last play lands, and the standings reshuffle.
Unattended, the 246-play week replays in under 2 minutes and the whole step
takes about 4 (measured 2026-10-14: 106 s of replay at ~430 ms of work per play,
on a QA build without the scoring fix that rides with this change). At
`--pace 4` it takes about 20 minutes (measured on rel-20261012-db4d68).

→ **Watched: hand back now** and wait for his go-ahead; unattended: check it and go on to step 4.

### Step 4 — conclude and pay

```bash
bin/qa-contest-rehearsal conclude                   # --cosign agent, the default: unattended
bin/qa-contest-rehearsal conclude --cosign link     # watched: he signs in Phantom
```

Grades the contest, ranks the entries, and settles. Under `--cosign agent` the
driver signs with the seated devnet agent key, claims the settle row
`submitted` with the transaction's signature BEFORE it broadcasts (the Treasury
page's order), then confirms on the dyno with the same checks the Treasury page
runs (`TxVerifier` per signer, then the contest is marked settled). If the send
or the verification fails, the row stays `submitted` naming its transaction:
press **Reconcile** on Treasury; never re-run the settle. Under `--cosign link` the server has already
signed with its own key and the second signature is Alex McRitchie's, from the co-signer
wallet the step prints.

```text
Magic Link:   https://qa.turfmonster.media/l/<token>   → /admin/pending_transactions
Contest:      https://qa.turfmonster.media/contests/<slug>
```

**On the Treasury page, press Co-sign** with that wallet active in Phantom. The
page builds a fresh transaction at the click; there is no Rebuild button and no
blockhash clock to race. Phantom asks for one approval. It worked when the row
reads **Confirmed**. A row that reads **Broadcast · unreconciled** takes
**Reconcile**, not a second Co-sign.

**Check the arithmetic afterwards.** The prize pool should fall by exactly the
sum paid, and each winner's balance should rise by exactly their rank's payout.
That subtraction is the proof the payout landed — not the transaction signature,
which only proves something was broadcast.

→ **Unattended: check the arithmetic and go on. Watched: hand back now.** Step 4
has three exits:

| Exit | Who acts next |
|---|---|
| `--cosign agent` | Nobody: the row reads `confirmed`; check the arithmetic, then `close` |
| `--cosign link` | **He does.** He signs in Phantom; you cannot do this half |
| nobody was owed | Nobody — the contest graded with no winner to pay |

On `--cosign link` **nothing can proceed until he signs**: only the server's half
is signed, so continuing past it closes a contest that never paid.

### Step 5 — close

```bash
bin/qa-contest-rehearsal close
```

Reclaims the contest's rent. A run that ends here is asset-positive.

Closing sweeps the prize pool, so `close` refuses a contest that has neither
settled on chain nor been cancelled. The refusal names the Treasury buttons:
Co-sign on a Pending row, or Reconcile on a row that reads Broadcast ·
unreconciled. Run `close` again once the row reads Confirmed.

```text
Contest:      https://qa.turfmonster.media/contests/<slug>
```

**Look at the contest page one last time.** It should read settled, with the
final standings and each winner's payout beside their rank. That is the same
page the operator would open to answer "did this contest actually pay out?" —
so it is the one worth leaving open.

→ **Report.** The rehearsal is done; report the contest slug, the signatures and the arithmetic.

### As the release's devnet gauntlet

When the rehearsal runs for a release candidate (a release carrying turf-monster or
turf-vault work, [`qa-release`](../../avi/sops/qa-release.md), "The devnet gauntlet"),
`bin/release prepare` runs it, unattended, once QA is green: every step above with
`--cosign agent`, the check at each STOP block, the arithmetic from the settle
transaction's token balances, and then a completed `devnet_gauntlet` event on the
release naming the contest slug and both signatures (or a `fail` naming the step,
with prepare exiting 4). The event's `metadata.shas` names the QA-deployed SHA of
each Turf repo the rehearsal ran against. Prepare runs it automatically, and
`bin/release cycle` re-runs prepare when one is owed; a watched hand run (`--cosign
link`) happens only when Alex McRitchie asks to watch, and records the same event by
hand with `metadata.shas` ([`qa-release`](../../avi/sops/qa-release.md), "The devnet
gauntlet"). Production waits for that record:
[`production-deploy`](../../steffon/sops/production-deploy.md) and `bin/release ship`
accept only the NEWEST `devnet_gauntlet` event on the release, only when it is
completed, and only when its `metadata.shas` match the Turf SHAs being shipped. A
failed run newer than a green one, a green one with no SHAs, or a green one for other
Turf code is a refusal (`Release::DevnetGauntlet.covers?`).

## What this does NOT cover

Stated so nobody reads a green rehearsal as more than it is:

- **The browser create path.** Step 1 uses the server-funded console path, not
  the Phantom create flow.
- **The browser entry path.** Step 2 drives the same HTTP endpoints a browser
  does and runs every server-side gate, but no page is rendered and no wallet
  extension is exercised.
- **Mainnet.** Every guard in this act exists to keep it off mainnet.

## Background — not needed to execute

What each step needs on QA, and the operator's part of the settlement, are in
`turf-monster/docs/qa-contest-rehearsal.md`. Design and mechanics of the driver
live with the code in `turf-monster/lib/turf_monster/qa_rehearsal/`. The scoring pipeline it borrows
is [`live-score-watch`](live-score-watch.md).
