# Full Cycle

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](../../../modules/token-session.md)).

## Status: Active

This is Mason's `full-cycle` SOP. It runs review, QA release, production deploy
and the close-out archive with explicit ship authority.

## Scope

`full-cycle` composes existing release atoms:

1. [`pr-review`](../../carl/sops/pr-review.md): a Carl primary plus a light on each
   submitted PR, merging approved work into `accepted`.
2. Avi's self-healing [`qa-release`](../../avi/sops/qa-release.md) (`bin/release prepare`).
3. Steffon's [`production-deploy`](../../steffon/sops/production-deploy.md)
   (`bin/release ship --mode cleared`).
4. [`archive-shipped`](../../steffon/sops/archive-shipped.md) (`bin/release archive`).

Atoms 2 to 4, with a QA verify after prepare and a prod verify after the ship, run
as ONE resumable command: `bin/release cycle --clearance "<Alex McRitchie's words>"
--yes`. Review is the only atom you run before it.

This SOP crosses the production gate. Use it only when Alex McRitchie launched
`full-cycle` or otherwise granted production ship authority in this session.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

There is work to move:

- submitted PRs to review
- reviewed work to prepare
- an assembled release to ship

If the queue is empty and `release == main`, report "nothing to run" and stop.

## Procedure

Refresh intake:

```bash
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster,rolio
```

Review first, then hand the rest of the release to ONE command:

```bash
# pr-review atom: review submitted PRs to reviewed or blocked
bin/release cycle --clearance "<Alex McRitchie's words>" --yes --wait-for-1password
```

`bin/release cycle` is the procedure for steps 2 to 4 below. It runs `prepare` →
QA verify (each QA app the release carries answers 200 on `/up` and `/`; a Turf
release has a green devnet gauntlet on the record for the Turf SHAs QA runs now, or
prepare runs one) → `ship --mode cleared` with his words → prod verify (`/up` and
`/` again, and each app with a prod deploy runs the SHA the ship pushed, else the
SHA QA froze: the Heroku release history, where a config-var or add-on change after
the deploy still counts and a rollback does not, or the deploy workflow's run, read
under the agent token; read three times 20 seconds apart, then a mismatch or an
unreadable answer stops it, exit 5) → `archive`,
one line per act with its elapsed time and the DevOps estimate's ETA. It owns the
plumbing the hand-rolled scratch scripts carried: OP_CACHE=false, the AGENT GitHub
token for prepare and archive, the admin 1Password token and DEPLOYER token for
ship (minted fresh for every act, never left empty), a one-hour CI poll budget, and
`caffeinate` tied to its own pid. It re-runs a step ONCE on a transient GitHub
network failure (`Failed to connect to github.com`, `Timeout was reached`, `Could
not resolve host`) or on prepare's stale-tree refusal (a newcomer landed on
`accepted`), and re-runs prepare once when ship refuses for a missing gauntlet.

It enters at the board's own stage, so **re-running it is the recovery** for an
interruption: none or `assembling` → prepare; `assembled` → QA verify; shipped
with an archive owed → prod verify. It refuses without `--clearance` (exit 2) and
stands down when another session holds the release claim (exit 10). Otherwise its
exit is the stopped act's: 3 QA not green, 4 gauntlet red, 5 a URL did not answer
200, 9 a token could not be minted. On 3 or 4, the per-atom recovery below applies.
The atoms remain callable one by one (`bin/release prepare --yes`, `bin/release
ship --mode cleared --clearance "…" --yes`, `bin/release archive --yes`) when you
need to stop between them.

**The cycle's prepare is always bare: it sweeps EVERY reviewed task, and takes no
`--task`.** Its retries and gauntlet re-runs are bare too, so work that reaches
`reviewed` mid-run rides under the same clearance; the cycle names the release and
its repos on the line before the ship. When Alex McRitchie scoped the release ("ship
the two"), run the atoms with `--task` instead.

**Posture per atom — delegate the READS, direct-drive the MUTATIONS.** Any op that
MUTATES shared state across many minutes is DIRECT-DRIVEN by this orchestrating
session, never handed to an ephemeral subagent: a subagent that detaches (crash,
timeout, killed terminal) leaves the mutation HALF-APPLIED with no attached
terminal to notice or finish it. Subagents stay first-class for **read** fan-out,
where a detach costs a retry. The line is **mutating vs reading**, not *parallel vs
serial*.

Steps 2 to 4 are what `bin/release cycle` runs for you, in this session. Run them
by hand only for a release Alex McRitchie scoped, carrying his `--task <slug>` flags
on every `prepare` below, or to stop between one step and the next; recovery from an
interruption is re-running the cycle.

1. **Review** — READ fan-out, so DELEGATE, by the
   [`pr-review`](../../carl/sops/pr-review.md) procedure. There is no Avi
   supervisor layer: this session claims each PR and spawns one **Carl**
   subagent (`subagent_type: carl`) per PR, labelled `review: <slug>`; Carl
   summons his light as his own child, drives the verdict and merges. A Carl and
   his light count as two toward the cap of five. Review mutates nothing but a
   task stage and the `accepted` merge, and a detached reviewer costs a retry.
2. **QA release** — MUTATION, so DIRECT-DRIVE `bin/release prepare [--task <slug> ...] --yes` from
   THIS session. Do NOT wrap it in a Steffon subagent. (Not theoretical: on
   2026-07-11 it WAS delegated, the subagent detached mid-sweep, and it stranded a
   partial release candidate — merged onto `release`, but never gated, deployed, or
   assembled. It sat there unnoticed.)

   **Recovery — diagnose before you re-run.** If the sweep was **INTERRUPTED** (no
   verdict — it detached, crashed, timed out): **re-run the same `bin/release
   prepare` line, `--task` flags included**; it is self-healing, and only a live terminal can run it. If it
   **ABORTED** (exit 1 — a verdict such as a red pre-QA gate) or came back **NOT
   GREEN** (exit 3 — a QA app never booted, members stay `reviewed`): **fix or
   eject the offender FIRST**, because a bare re-run re-deploys the same member
   code and goes red again. The exit table and the full abort table are in
   [`../../avi/sops/qa-release.md`](../../avi/sops/qa-release.md).
3. **Ship** — MUTATION, so DIRECT-DRIVE `bin/release ship --mode cleared
   --clearance "<Alex McRitchie's words>" --yes` from THIS session. Do NOT wrap the ship in a subagent: it is the one irreversible gate,
   and a wrapper agent that dies mid-ship would orphan the `release → main` state
   with no terminal to recover it.
4. **Close out** — MUTATION, so DIRECT-DRIVE `bin/release archive --yes` (preview
   with `--dry-run` first). This is
   [`archive-shipped`](../../steffon/sops/archive-shipped.md), the beat
   `production-deploy` ends on: the cycle this run just shipped gets archived,
   its desks reclaimed and its regenerable disk swept. **Only after a GREEN
   ship** — an aborted ship has nothing to archive. The archive is a separate
   verdict and may refuse (a ledger that lost rows); a refusal does NOT unship
   anything, so recover the row and re-run the archive rather than touching the
   release.

- **Visibility is not a reason to delegate.** The sub-agent tree is ephemeral (it
  dies with the session) and the autonomous heartbeat has no terminal, so it
  renders no tree at all. The durable, full-visibility surface is the Activities
  timeline — narrate each atom there.

Keep the same guards each atom owns:

- Review in waves of five or fewer reviewers.
- Use Avi's `qa-release` sweep for merge plus QA.
- Ship only after QA-green.
- Do not deploy production unless ship authority is explicit.
- Archive only after a green ship, and report its result separately.

Review takes time; new PRs may land in `submitted` meanwhile. Before you launch
the cycle, re-check `bin/task list --stage submitted` and run one straggler round of
review. Then launch `bin/release cycle`: its prepare is bare and sweeps every
`reviewed` task, the stragglers included. Once the cycle has started, a straggler
waits for the next release; do not interleave a hand-run `prepare` with a running
cycle.

When you run the atoms by hand, a straggler round between `prepare` and `ship`
re-runs the SAME `prepare` line you ran, flags included. On a release Alex McRitchie
scoped, that means his `--task <slug>` flags, and a straggler joins only when his
scope names it: a bare `bin/release prepare --yes` sweeps every `reviewed` task
into the candidate, past his scope.

Cold start note: launched bare, you are the conductor (Deploy lane), not a
feature agent — do not follow the build gate's task/worktree flow. You
orchestrate review, sweep, and ship on work that is already built; you do not
review diffs yourself, create tasks, or write feature code.

For a single-task expedite, run Avi's
[`deploy-with-task`](../../avi/sops/deploy-with-task.md) SOP instead of pushing
one task past pending release work.

## Exit Seam

The release is shipped and the cycle is closed out, or the run cleanly reports no
work. Report:

- reviewed and blocked tasks
- QA URL
- production SHA
- release slug
- smoke result when a ship happens
- **the archive result, separately** — tasks archived and releases closed, or
  "nothing to archive", or the refusal and what it named

## Related

- [`../../../agents/carl/sops/pr-review.md`](../../../agents/carl/sops/pr-review.md)
  - review-only PR review (Carl).
- [`../../../agents/avi/sops/qa-release.md`](../../../agents/avi/sops/qa-release.md)
  - QA release sweep.
- [`../../../agents/steffon/sops/production-deploy.md`](../../../agents/steffon/sops/production-deploy.md)
  - production deploy.
- [`../../../agents/steffon/sops/archive-shipped.md`](../../../agents/steffon/sops/archive-shipped.md)
  - the closeout this cycle ends on.
