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

If there is nothing to archive, **still run the orphan sweep** below, then report
"nothing to archive" alongside its result and stop. The sweep reports orphans
**already on the board** — they do not depend on this run archiving anything, and
skipping it on a quiet run is exactly how one sits for a month. That is not
hypothetical: studio-engine #245 sat open under an archived task for a month and
surfaced only because a human finally asked for a backlog audit.

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
- **Then sweep for orphaned PRs, unconditionally.** `bin/task orphan-prs` is
  read-only, never blocks, and always exits 0, so it closes every run of this act
  — including one that archived nothing, and including one that ended in a
  refusal. See [the orphan sweep](#the-orphan-sweep--the-coverage-for-the-model-path)
  below for why it belongs to THIS act and how to read it.

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

**`bin/release archive` ends at step 10. The ACT does not.** One step remains, and
it is a separate command you run yourself:

11. Sweeps for orphaned PRs (`bin/task orphan-prs`) and reports them — read-only,
    never blocks, and run on **every** pass of this act including a no-op archive
    and an aborted one. It is the coverage for the model archive path; see
    [the orphan sweep](#the-orphan-sweep--the-coverage-for-the-model-path).

> ### ⛔ Step 7 BLOCKS step 8 — the run under-reclaims by design
> Archiving a task **lands a durable artifact on it**, and the reclaim's idle gate
> reads exactly that signal. So a desk whose task step 7 archived seconds earlier
> is withheld as active:
>
> ```
> withheld turf-monster/adopt-birthday-age-gate-flow: the bound task landed a
>   durable artifact 2m ago, inside the 1.5h idle window
> ```
>
> Measured 2026-08-26: the preview offered **7** desks and the run took **4**. Two
> were withheld by the run's own step-7 stamp. (The seventh was removed by a
> concurrent session mid-run, its task bouncing `building → designed` — a reminder
> that the preview is a snapshot, not a reservation.)
>
> **Do not force past this.** The gate cannot tell the archive's own stamp from a
> live agent's write, and it is right to refuse. The desks come back after the
> idle window: re-run the act — it is idempotent — or take a specific desk now
> with `bin/agent-worktree remove <app> <slug> --yes`.
>
> **Report the previewed count and the taken count separately.** Reporting the
> preview as the result overstates every archive run by whatever step 7 just
> stamped.

### The infra sweep (steps 2-3 / steps 8-9)

**The worktree reclaim and the artifact sweep are
[`clean-infra`](clean-infra.md)'s, and it is the single source for their
mechanics.** `bin/release archive` drives both inline — that is why they are
steps of this run rather than a separate command you invoke — but the safety
gates, the withholding rules, the logger-audit verdict table, and the hand-path
for a stale unmerged desk are all documented there, once.

Read [`clean-infra`](clean-infra.md) before approving the confirm at step 6 if
the preview offers up a desk you do not recognise. Two rules from it decide most
of those calls:

- **Clean + merged is NOT sufficient.** A fresh desk is git-identical to a merged
  one, so the reclaim also withholds a desk younger than 1h29m, one written to
  inside that window, and one whose holder has a gate in flight.
- **Read the `rationale:` line, not just `safe:`.** It names what every channel
  asked and answered; a channel that could not be asked says so.

The sweep's numbers are **machine-local** and belong in this act's report as
such. Its **improvement suggestion is not optional** — `clean-infra` requires a
run to end with one concrete proposal for making the next sweep smaller, and an
archive run that drives the sweep owes that proposal too.

Run the sweep on its own any time — but note that `bin/clean-artifacts` has **no
`--help`** and a bare invocation **applies**:

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
bin/archive-docs --help                     # usage; sweeps nothing, rolls nothing
bin/ledger-guard                            # the same invariant, on demand
```

**`--help` is safe to probe, and it was not always.** Until 2026-08-31
`bin/archive-docs --help` was not a help flag at all: the script read four exact
spellings out of `ARGV` and silently ignored everything else, so `--help` fell
through to a REAL roll — it rewrote `delete-later.md` by −41 lines and staged a
second file for an operator who was only asking what the command does. It now
prints usage and exits without touching the working tree or the index, and an
argument it cannot account for REFUSES rather than proceeding. The same guard
(`bin/lib/cli_arg_guard.rb`) covers `bin/clean-artifacts`, `bin/control-check`,
`bin/reap-cert-databases` and — since 2026-08-31 — `bin/release`, where the same
defect sat one position over: `bin/release prepare --yes --help` promoted for
real, because only the BARE form fell through to usage; `test/lib/bin_help_flag_class_test.rb` fails when
a new `bin/` script is added without deciding what it does with an unrecognised
argument.

### The orphan sweep — the coverage for the model path

This step is not a nicety bolted onto the end of the run. It is the other half of
a design that deliberately chose **not** to gate the bulk archive.

`bin/release archive` archives through `Release::Conductor.archive_completed!`,
which calls `task.archive!` on the **model**. That path **bypasses the CLI's
open-PR gate on purpose** (`lib/archive_holder_guard.rb`, "THIS GATE IS THE CLI
PATH, DELIBERATELY"), and it must keep bypassing it: the gate reads GitHub, the
App installation token expires about hourly **by design**, and a gate there could
refuse an entire release closeout on one stale read. **Refusing a closeout is
worse than a late orphan report** — and a gate that refuses most days gets
`--force`d until it protects nothing, which the holder guard already measured (31
of 34 refusals, then `--force` as muscle memory).

So the model path is ungated on purpose, and **this sweep is its coverage.** Do
not "improve" the model path while you are in here; improving it is how a
closeout starts failing on a credential.

Run it after every archive:

```bash
bin/task orphan-prs          # PRs still OPEN whose task is already archived
bin/task orphan-prs --json   # same finding set, machine-readable
```

One `gh pr list` per repo the archived tasks actually name — not one call per PR,
so it stays seven calls however large the board.

**How to read the output:**

| Line | What it means | What you owe |
|---|---|---|
| `ORPHANED  <repo>#<n>` | neither merged nor closed, and no board state describes it | name it in the report, and decide: merge it, close it, or revive the task |
| `abandoned on purpose  <repo>#<n>` | an abandonment receipt names that exact PR | nothing — the decision was made and recorded; it only needs to stay visible |
| `warning: <repo>: could not list open PRs — NOT checked` | that repo **was not swept at all** | refresh the token and re-run; if it still fails, report the repo BY NAME as unchecked |

`archived` is not a lock. **Reviving the task is a legitimate outcome** — often
the right one when the PR still carries work nobody re-derived.

> ### ⛔ An UNCHECKED repo is not a CLEAN repo
> The summary line — `(N orphaned PR(s), M deliberately abandoned, across K
> archived task(s))` — counts only the repos it could read. A repo whose
> `gh pr list` failed is named in a warning on **stderr** and is simply absent
> from that count, so a run printing `0 orphaned PR(s)` **while warning about a
> repo has told you nothing about that repo**. Almost always a stale token:
>
> ```bash
> eval "$(bin/gh-auth-refresh --export)"
> bin/task orphan-prs
> ```
>
> **Report every unchecked repo by name.** A scheduled report that quietly counts
> unchecked repos as clean is worse than no report: it converts an unknown into a
> false all-clear. That is the same species as the two false all-clears already
> measured in this exact surface — a substring prefix collision that read a live
> `/pull/24` as "abandoned on purpose" because a receipt for `/pull/245` contained
> its url, and the summary line that therefore reported `0 orphaned PR(s)` while a
> real orphan sat open. Both are fixed; the posture that caught them is what this
> callout preserves.
>
> **Two more silences the sweep can carry, so read stderr, not just the summary:**
> `warning: stopped after 40 pages` means the archived-task scan itself was
> truncated, and `gh_open_pr_numbers` truncates at `--limit 200` open PRs per repo
> **without saying so** (latent — no repo is near it; recorded on
> `/tasks/harden-open-pr-guard` as `activity-6499`. The fix is to PAGE, never to
> raise the number — a bigger limit is the same defect with a later trigger).

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
- **orphaned PRs** from `bin/task orphan-prs` — every `ORPHANED` line as
  `<repo>#<n>` plus the archived task that stranded it, and the decision you took
  or are handing on. Report `0 orphaned PR(s)` only when every repo was checked
- **any repo the sweep could NOT check**, by name — never folded into the clean
  count, and never omitted because the summary line already reads zero

On a clean no-op, report "nothing to archive." Note that a no-op archive can
still sweep real disk, and a fresh machine can sweep nothing while archiving
plenty — the two halves are independent.

## Related

- [`clean-infra.md`](clean-infra.md) - Steffon's infra sweep, which owns the
  worktree reclaim and artifact sweep this run drives at steps 2-3 and 8-9.
- [`production-deploy.md`](production-deploy.md) - the ship this act closes out;
  it runs `archive-shipped` as its final step.
- [`../../avi/sops/qa-release.md`](../../avi/sops/qa-release.md) - Avi's release prepare (assembler) SOP.
- [`../../alex/sops/clean-up.md`](../../alex/sops/clean-up.md) - Alex's board-to-zero
  act, which runs the same orphan sweep in its Phase 2 triage. That one is the EPISODIC
  deep clean an operator invokes when the board has fogged; this one is the BEAT,
  riding every archive. Two occurrences on purpose — keep them saying the same
  thing about how to read an unchecked repo.
