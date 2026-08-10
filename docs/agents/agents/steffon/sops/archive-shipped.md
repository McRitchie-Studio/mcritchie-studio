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

So a **fresh Mac's first archive run sweeps almost nothing, and that is
correct** — not an anomaly, and not a sign the sweep is broken. The disk numbers
describe the machine the command ran on. Never file them as pipeline state, and
never compare them across machines.

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
4. **`--dry-run` stops here.** Everything above mutates nothing.
5. One confirm authorizes all three mutations below.
6. Archives on the board (`shipped → archived`).
7. Reclaims the merged/shipped worktrees (`--reclaim --yes`).
8. Sweeps the regenerable artifacts (`bin/clean-artifacts`) — **after** the
   reclaim, so worktrees that just went away are not swept and counted twice.

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

On a clean no-op, report "nothing to archive." Note that a no-op archive can
still sweep real disk, and a fresh machine can sweep nothing while archiving
plenty — the two halves are independent.

## Related

- [`../../avi/sops/qa-release.md`](../../avi/sops/qa-release.md) - Avi's release prepare (assembler) SOP.
