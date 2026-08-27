# Clean Infra

## Status: Active

This is Steffon's `clean-infra` SOP. It reclaims **this machine's** local
infrastructure: finished worktrees, the Redis band they hold, regenerable disk
(logs, caches, coverage), orphaned per-desk databases, and stale stack pids.

It is the house's answer to **"an agent says there is no space."** That report
arrives in several disguises — a worktree that will not allocate, a suite that
dies on disk, a stack that will not boot — and they share one cause: the machine
is carrying work that finished. This act is where that gets swept, whatever the
symptom looked like.

It is Steffon's because every resource it touches is platform state, and the
gates it must respect are release gates.

## What this act is NOT

- **It is not `archive-shipped`.** That act closes out the BOARD — shipped tasks,
  completed releases — and retires frozen docs into the archive as a tracked
  commit. This act touches no board row and no tracked file. `archive-shipped`
  runs this sweep as part of its own procedure; running this act alone never
  archives anything.
- **It is not `clean-up`.** Alex's act drives the BOARD to zero and triages open
  tasks and orphaned PRs. It calls this act for the infra half.
- **It never reviews, merges, promotes, or deploys.**

## The one thing to get right before reporting numbers

Everything here is **machine-local**. Reclaimed desks, swept bytes, band width,
rotation verdicts — all describe the machine the command ran on, and none of it
is pipeline state. **A fresh Mac sweeps almost nothing, and that is correct.**
Never file these numbers as board state and never compare them across machines.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat steffon
```

Use the production board by default for any read. Do not add `--local`.

## Preconditions

1. **No release is in flight.** A live `bin/release prepare` or `bin/release
   ship` holds a conductor claim, and the reclaim withholds `_ship` / `_gate`
   while it does. Check first:

   ```bash
   bin/release status
   ```

   If a release is live, the sweep still runs — it simply leaves those two
   workspaces alone and says so. Do not override it.

2. **Know your carve-out.** Any worktree, desk, or database belonging to work
   this session or another live session is invisible to this act. Name it before
   you start. **A missed sweep costs one command next time; a reclaimed desk
   costs somebody's uncommitted work.**

## Procedure

**Direct-drive this act — do NOT delegate it to a subagent.** It mutates shared
machine state over many minutes. A detached subagent leaves a half-torn desk with
no terminal to finish it. Re-running is safe: every step below is idempotent.

### Step 1 — Census, before you judge

```bash
bin/agent-worktree list            # per desk: clean/dirty, merged/unmerged, redis=<n>, +N/-M vs BASE
bin/agent-worktree scale status    # band: floor, current, used, free, physical cap
bin/clean-artifacts --dry-run --skip-audit   # what disk is reclaimable, per repo and worktree
```

Read the numbers before deciding anything. The band's `free` count is what a
"no space" report usually means; `physical` is the hard ceiling that only
`scale --provision` can raise.

### Step 2 — Reclaim the finished desks

```bash
bin/agent-worktree cleanup                   # dry run — read it
bin/agent-worktree cleanup --reclaim         # dry run: what is SAFE (clean + merged + unoccupied)
bin/agent-worktree cleanup --reclaim --yes   # full teardown + Redis band shrink
```

- **Clean + merged is NOT sufficient, and never was.** A brand-new worktree is
  git-identical to a merged one — clean, nothing ahead of base — so it passes the
  git test vacuously. On 2026-08-13 that destroyed a live builder's desk
  mid-task. The reclaim now also withholds a desk younger than 1h29m, one written
  to inside that window, or one whose holder has a gate in flight (a cert writes
  nothing into its desk for up to 94 minutes). **Expect finished desks to linger
  up to 1h29m.** That is the trade, and it is deliberate. Use `bin/agent-worktree
  remove <app> <task-slug> --yes` when you need a specific one gone now.
- **An OPEN unmerged PR withholds a desk, and so does a live reviewer.** A branch
  whose diff against base is empty is git-eligible while its PR is still open, and
  a reviewer works a builder's desk without ever taking the build claim. Both are
  channels of the same gate.
- **Read the `rationale:` line, not just `safe:`.** `safe: merged on
  origin/accepted (clean)` is a git fact, and on 2026-08-14 it was true of all
  three load-bearing desks a 29-candidate dry run offered up. Each candidate
  prints what every channel asked and answered; a channel that could not be asked
  says so (`GitHub unreachable`). That line is the approval packet — a blind
  channel gets fixed before the batch is approved.
- **Trust the gate over the description.** If the count you were told and the
  count the dry run finds disagree, surface the discrepancy and believe the gate.
- **`_ship` and `_gate` are infrastructure, not desks.** Safe to reclaim BETWEEN
  releases (`bin/release.rb` re-creates them on demand); withheld automatically
  while any conductor claim is live in either role. Re-run once the release
  completes.

> ### ⛔ The reclaim refuses a desk whose commits live nowhere else — LISTEN to it
> `bin/agent-worktree remove` refuses with *"branch content is not represented on
> origin/release"*. That is the gate catching a detached-HEAD worktree whose
> commits are reachable from nothing but that directory. Delete it and the work is
> garbage-collected. Make the commits safe first:
>
> ```bash
> SHA=$(git -C .worktrees/<name> rev-parse HEAD)
> git tag archive/<name> "$SHA" && git push origin refs/tags/archive/<name>
> git worktree remove --force .worktrees/<name> && git worktree prune
> ```
>
> The gate cannot see a tag, so it keeps refusing — but the tag satisfies its
> actual concern. **Record the override in the ledger.**

### Step 3 — Stale unmerged desks, by hand

The reclaim can never take these: a clean desk on a genuinely **unmerged** branch
is invisible to its safety gate, and these accumulate until they pin the band
wide (2026-08-08: 14 of 27 surviving slots were exactly this). `remove --force`
does not help — it clears the content guard only for the merged-PR case.

Exclude first, then triage what survives. Never reach a desk whose task is in any
OPEN stage, whose stack is `up`, which holds a live builder claim, which is
`_ship`/`_gate`, or which is in this run's carve-out.

For each survivor, with `<wt>` = `/Users/alex/projects/<app>/.worktrees/<slug>`:

```bash
git -C <wt> status --porcelain                       # MUST be empty; a dirty desk EXITS this
                                                      # protocol — it may hold unlanded work
git -C <wt> branch --show-current                     # EMPTY = detached → the block above, not this
git -C <wt> rev-list --count origin/<branch>..HEAD    # UNPUSHED, vs the desk's OWN remote branch
bin/task show <slug>                                  # board stage
```

**Preserve before removing** — no case falls through to deletion:

- **Task in an open stage** — stop; it belongs to its lane.
- **Zero unpushed, task archived or absent** — nothing owed; origin holds it.
- **Unpushed commits, or branch absent from origin** — push it:
  `git -C <wt> push -u origin feat/<slug>`.
- **Push refused as non-fast-forward** — never force-push an archived task's
  branch. Tag the local HEAD instead:
  `git -C <wt> tag archive/<slug>-local $(git -C <wt> rev-parse HEAD) && git -C <wt> push origin refs/tags/archive/<slug>-local`.

**Before writing any desk off, diff its ideas against its base branch and ask:
did this land, or did we re-suffer it?** A branch is superseded only if you can
point at the code that supersedes it. Record the verdict or the debt in
[`../../../maintenance/parking-lot.md`](../../../maintenance/parking-lot.md).

Then tear down in the launcher's own order — this hand-path drives raw git and
bypasses every check above, so **re-assert the carve-out and the exclusions
immediately before this block**:

```bash
bin/agent-worktree down <app> <slug>       # STOP THE STACK FIRST. Skip when the list row
                                            # says missing-env: `down` aborts without a stack env.
[ -z "$(git -C <wt> status --porcelain)" ] || { echo "DIRTY — STOP"; exit 1; }
redis-cli -n <db> flushdb                  # <db> from step 1's list row; skip when blank
git -C /Users/alex/projects/<app> worktree remove .worktrees/<slug>   # UN-forced — keep the guard
git -C /Users/alex/projects/<app> branch -D feat/<slug>               # only after the tip is on origin
git -C /Users/alex/projects/<app> worktree prune
```

Hand-edit `docs/agents/maintenance/delete-later.md` to record the override — no
CLI path writes an unmerged desk there.

### Step 4 — Sweep the regenerable disk

```bash
bin/clean-artifacts --dry-run     # report only, change nothing
bin/clean-artifacts               # APPLIES the sweep
bin/clean-artifacts --skip-audit  # sweep without booting any app (fast)
```

> ### ⛔ `bin/clean-artifacts` has NO `--help`, and a bare run APPLIES
> Only `--dry-run` previews. Every other argument — including `--help` — is
> ignored, and the script sweeps for real. Probing it to "see the options"
> truncates live logs and clears every `tmp/cache` across all managed repos and
> worktrees. Nothing tracked is lost, so this is recoverable; it is still a
> mutation you did not intend. **Preview with `--dry-run`, never with a flag you
> are guessing at.**

It reclaims live logs (truncated in place, so a running server keeps its handle),
rotated logs, `tmp/cache`, `tmp/brakeman.json`, and `coverage/` across every
managed Rails repo and every worktree under them. It never touches `tmp/pids`,
`tmp/sockets`, `tmp/storage`, `db/`, `storage/`, `.env`, or any tracked file.
Repos are **discovered** (anything with `config/environments`), so a new
satellite is swept the day it lands.

It also boots each app and reads its live logger, so the run reports any app
whose local logs are not capped. That check is behavioral on purpose: a cap set
at the wrong point in the boot reads correct in the config file and does nothing
at runtime.

| Verdict | Meaning | What to do |
|---|---|---|
| `OK` | bounded at a sane cap | nothing |
| `LOOSE` | rotating at Rails' own 100 MB default — the studio-engine cap is **not** installed | the app needs the `studio-engine` bump adopted |
| `NONE` | not rotating at all | same, and more urgent |
| `?` | the app could not be booted (reason given) | inconclusive — never read it as pass or fail |

Two things rotation can never reach are **reported and never deleted**: scratch
validator ledgers (`*/test-ledger`) and stray files at the projects root.
Removing a whole data directory is a different risk class from truncating a log,
so that call stays with Mr. McRitchie.

### Step 5 — Contract the band, then check the machine

```bash
bin/agent-worktree snapshot --write   # registry only — does NOT touch the band
bin/agent-worktree scale in           # contracts ONE 10-slot step per call — repeat
bin/agent-worktree scale status       # read the result
bin/agent-worktree doctor             # stale pids, missing DBs, orphaned Redis
```

`scale in` **refuses the whole step if ANY allocated DB sits above the target**,
so one live session near the top of the band blocks the entire contraction. Free
the highest desks first, and expect the band to stay wide until they close. A
full 55 → 20 contraction is four calls, not one.

Kill stale stack pids and drop orphaned per-desk databases that `doctor` names.
Append anything you are unsure about to
[`../../../maintenance/delete-later.md`](../../../maintenance/delete-later.md)
rather than deleting it.

> **The reclaim dirties the primary.** It appends audit rows to
> `delete-later.md` in the primary checkout — and **the ship requires a clean
> primary.** Move that change into a worktree and commit it through a PR. Do not
> commit from the primary, and do not throw the ledger away.

## The "no space" fast path

When an agent reports it cannot allocate, run the census (step 1) and read one
number:

| What the census says | What it means | Do |
|---|---|---|
| band `free: 0`, `current` < `physical` | the band is full but the machine has room | step 2, then step 5's `scale in` is not needed — allocation auto-grows |
| band `free: 0`, `current` == `physical` | the hard Redis ceiling | step 2 to free slots. Only `bin/agent-worktree scale --provision` raises it, and it RESTARTS Redis and bounces every running stack — leave that for the QA/infra lane |
| disk pressure, band healthy | regenerable disk | step 4 |
| a desk will not boot or its DB is missing | orphaned per-desk state | step 5's `doctor` |

Report which of these it was. "Ran out of space" and "the band hit its physical
ceiling" are different problems with different fixes, and only one of them is
solved by sweeping.

## Exit Seam

The machine is carrying only live work. Report:

- worktrees reclaimed, and **any withheld and why** (the `rationale:` line)
- Redis band before → after, and whether the floor or a high desk stopped it
- **reclaimed bytes** from the artifact sweep, labelled **this machine only**
- **any app named `LOOSE` or `NONE`** by the logger audit — name each one, and say
  plainly that its local logs are still growing to Rails' 100 MB default
- any app the audit could not boot, with the reason
- stale pids killed, orphaned databases dropped
- anything appended to the ledger rather than removed

On a clean run, report "nothing to reclaim" — and note that a no-op reclaim can
still sweep real disk. The two halves are independent.

## Conclude with an improvement — REQUIRED

**Every run of this act ends with one concrete suggestion for making the next run
smaller.** Not a summary of what was swept: a proposal about the architecture or
the process that produced the mess.

This is the point of the act. Sweeping is maintenance; the sweep's own numbers
are the only regular evidence the house gets about which of its habits leak.
A run that reports bytes and stops has thrown that evidence away.

Ground the suggestion in what THIS run measured:

- **What came back?** A desk class, an app, a directory that also filled last
  time is a design problem wearing a housekeeping costume.
- **What was withheld, repeatedly?** A gate that keeps refusing the same desk is
  either protecting something real that nobody has resolved, or miscalibrated.
- **What needed a hand-path?** Step 3 exists because the reclaim cannot take
  unmerged desks. Every desk that reached it is a candidate for automation.
- **What surprised you?** A trap you hit is a trap the next agent hits.

State it as: **the observation, the cost, and the proposed change** — one short
paragraph, no more. File it in
[`../../../maintenance/parking-lot.md`](../../../maintenance/parking-lot.md) when
it needs building, and say in the report where it went. If the run genuinely
surfaced nothing new, say that plainly rather than inventing a suggestion — but
say it, so the silence is a finding rather than an omission.

## Related

- [`archive-shipped.md`](archive-shipped.md) - Steffon's board closeout, which
  runs this sweep as part of its own procedure.
- [`../../alex/sops/clean-up.md`](../../alex/sops/clean-up.md) - Alex's
  board-to-zero act, which calls this one for the infra half.
- [`../../../modules/worktrees.md`](../../../modules/worktrees.md) - the worktree
  launcher, the Redis band, and the lifecycle verbs.
