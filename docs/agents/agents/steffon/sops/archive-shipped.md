# Archive Shipped

## Status: Active

This is Steffon's `archive-shipped` SOP. It closes out shipped work from prior
release cycles, reclaims completed worktrees, and sweeps the regenerable disk
those cycles left behind. `archive-completed` is the legacy name for this same
act.

## Scope

Archive work only after it is already shipped. This SOP does not review PRs,
merge release work, deploy QA, or ship production.

## Two kinds of state — read this before reporting numbers

This act touches **the board** and **this machine's disk**, and they are not the
same kind of fact:

| What | Where it lives | Notes |
|---|---|---|
| archived tasks, completed releases | the **production board** | shared; `--local` is never added (see Entry) |
| reclaimed worktrees, swept bytes, rotation verdicts | **this machine only** | never board state |
| retired docs, ledger rollover | **the repo** | staged, then committed to `release` |

So a **fresh Mac's first archive run sweeps almost nothing, and that is
correct** — not an anomaly, and not a sign the sweep is broken. The disk numbers
describe the machine the command ran on. Never file them as pipeline state, and
never compare them across machines.

The doc retirement is the exception to "machine-local": it edits **tracked
files**, so the run stages the moves and commits them to `release` with the
ledger in one artifact commit. It therefore does the same thing on any machine.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

- At least one shipped task or completed release is ready to archive.
- The worktree cleanup candidate is merged or main-equivalent.
- No feature worktree with unmerged or dirty work is reclaimed.

If there is nothing to archive, report "nothing to archive" and stop.

## Procedure

**Direct-drive this act — do NOT delegate it to a subagent.** Archiving mutates
shared state (it archives tasks and releases, and reclaims worktrees, branches,
and Redis slots) over many minutes. Run it in the conductor session itself.

- **The rule.** Any op that MUTATES shared state across many minutes —
  `archive-shipped`, `qa-release`, `production-deploy` — is direct-driven by the
  conductor session, never handed to an ephemeral subagent that can detach and
  leave the mutation half-applied. Subagents stay first-class for **read** fan-out
  (reviews, audits, searches), where a detach costs a retry. The line is
  **mutating vs reading**, not *parallel vs serial*.
- **Recovery.** `bin/release archive` is idempotent — a re-run archives nothing
  twice. If a run is interrupted, re-run it.

Preview first:

```bash
bin/release archive --dry-run
```

If the preview matches the shipped/completed work you intend to close:

```bash
bin/release archive --yes
```

`--yes` only answers the non-interactive confirmation. It does not bypass archive
eligibility, worktree safety checks, release membership checks, or Redis-band
cleanup guards.

### What the run does, in order

1. Plans the archivable shipped tasks (a board read).
2. Previews the worktree reclaim (`bin/agent-worktree cleanup --reclaim`).
3. Previews the artifact sweep (`bin/clean-artifacts --dry-run`).
4. Previews the doc retirement (`bin/archive-docs --dry-run`).
5. **`--dry-run` stops here.** Everything above mutates nothing.
6. One confirm authorizes every mutation below.
7. Archives on the board (`shipped → archived`).
8. Reclaims the merged/shipped worktrees (`--reclaim --yes`).
9. Sweeps the regenerable artifacts (`bin/clean-artifacts`) — **after** the
   reclaim, so worktrees that just went away are not swept and counted twice.
10. Retires frozen docs + rolls the ledger (`bin/archive-docs`), then commits
    that and the ledger to `release` in ONE artifact commit.

### The artifact sweep (step 3 / step 8)

`bin/clean-artifacts` reclaims regenerable disk across **every managed Rails repo
and every worktree under them** — live logs truncated in place (a running server
keeps its handle), rotated logs, `tmp/cache`, `tmp/brakeman.json`, `coverage/`.
It never touches `tmp/pids`, `tmp/sockets`, `tmp/storage`, `db/`, `storage/`,
`.env`, or any tracked file. Repos are **discovered** (anything with
`config/environments`), so a new satellite is swept the day it lands.

It also **boots each app and reads its live logger**, so the run reports any app
whose local logs are not capped. That check is behavioral on purpose: a cap set
at the wrong point in the boot reads correct in the config file and does nothing
at runtime. Verdicts:

| Verdict | Meaning | What to do |
|---|---|---|
| `OK` | bounded at a sane cap | nothing |
| `LOOSE` | rotating at Rails' own 100 MB default — the studio-engine cap is **not** installed | the app needs the `studio-engine` bump adopted |
| `NONE` | not rotating at all | same, and more urgent |
| `?` | the app could not be booted (reason given) | inconclusive — never read it as either pass or fail |

Two things rotation can never reach, because they are not Rails logs, are
**reported and never deleted**: scratch validator ledgers (`*/test-ledger`) and
stray files at the projects root. Removing a whole data directory is a different
risk class from truncating a log, so that call stays with Mr. McRitchie.

Run it on its own any time:

```bash
bin/clean-artifacts --dry-run     # report only
bin/clean-artifacts --skip-audit  # sweep without booting any app (fast)
```

### The doc retirement (step 4 / step 10)

`bin/archive-docs` retires frozen snapshots out of the **live** doc tree into
`docs/agents/archive/`. Audits from May, release retros from June, a closeout
from the 14th: all true when written, all frozen on purpose, all sitting in the
same folders as the living instructions, so every doc sweep and terminology pass
wades through them.

**A file qualifies only when BOTH hold:**

1. its name carries a date (`YYYY-MM-DD` or `retro-rel-*`) **or** it lives in
   `docs/agents/audits/`; **and**
2. nothing in the live tree references it — checked at **run time**, per file,
   across the whole repo (docs *and* code).

Both halves are load-bearing. Rule 1 alone would sweep live handoffs — the
undated kickoff docs and the parking lot are current instructions. Rule 2 alone
would sweep nothing, because these snapshots cite each other: a reference from
another file that is **also retiring** does not pin anything, so a cluster
retires together, while a reference from anything that **stays** (a module doc,
`config/satellites.yml`, `bin/dor-check`) pins the file where it is.

**Nothing is ever deleted.** Every retirement is a `git mv` into
`docs/agents/archive/`, mirroring the source subdirectory so siblings keep
resolving each other's links. History survives either way, but a move keeps a
stale inbound link resolvable by search instead of turning it into a dead end.

**A still-referenced snapshot is skipped and named.** It is someone's live
citation: fix the referrer first, deliberately, and it retires on the next run.

The ledger rolls over on the same beat: rows in
`docs/agents/maintenance/delete-later.md` whose status date is older than the
current release cycle move to `docs/agents/archive/maintenance/`. Rows with **no
date** — `pending approval`, `reference only` — are unresolved work and always
stay live.

**The beat refuses to sweep a ledger that has lost rows, and the refusal stops
the beat.** A dated row is a teardown that happened, and it may only ever MOVE
between the ledger and its archive. `bin/archive-docs` checks that against `HEAD`
before the roll and again after it, and an apply exits non-zero naming every
destroyed row (a `--dry-run` reports and still exits 0, so a preview never wedges
the callers that preview before confirming). `bin/release archive` **honours that
exit code**: it aborts before `commit_artifact_to_release`, so the destroyed
ledger is never committed to `release`.

Both halves are load-bearing, and the second one is easy to lose. When the
refusal first shipped it was **inert** through the only caller that matters —
`sweep_docs` returned `[out, ok]` and both call sites took `.first`, so the
warning printed and the beat committed the loss anyway. If you change how
`sweep_docs` is called, `test/lib/release_archive_docs_refusal_test.rb` is what
holds the seam.

The board archive, the worktree reclaim, and the artifact sweep all run **before**
this point and are idempotent, so an abort here is safe to resume: recover the
row, then re-run `bin/release archive`. If it fires, do not edit the guard —
recover the row with `git show HEAD:docs/agents/maintenance/delete-later.md` and
put it back.

```bash
bin/archive-docs --dry-run                  # report only
bin/archive-docs --ledger-cutoff=2026-08-09 # override the derived cycle boundary
bin/ledger-guard                            # the same invariant, on demand
```

## Exit Seam

Shipped tasks and completed releases are archived, safe completed worktrees are
reclaimed, and regenerable disk is swept. Report:

- archived task count
- completed release count
- reclaimed worktrees
- any worktree intentionally left alone and why
- **reclaimed bytes** from the artifact sweep, labelled as **this machine only**
- **any app named `LOOSE` or `NONE`** by the logger audit — name each one, and
  say plainly that its local logs are still growing to Rails' 100 MB default
- any app the audit could not boot, with the reason
- **retired-doc count** and the ledger rows rolled over
- **any doc skipped for being still referenced** — name the file AND its
  referrer, so the citation can be fixed deliberately rather than orphaned

On a clean no-op, report "nothing to archive." Note that a no-op archive can
still sweep real disk, and a fresh machine can sweep nothing while archiving
plenty — the two halves are independent.

## Related

- [`../../avi/sops/qa-release.md`](../../avi/sops/qa-release.md) - Avi's release prepare (assembler) SOP.
