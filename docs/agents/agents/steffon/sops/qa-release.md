# QA Release

## Status: Active

This is Steffon's `qa-release` SOP. It is the self-healing release prepare sweep:
detect reviewed work and release stragglers, merge them onto `release`, run the
pre-QA gate, deploy QA, and flip members to `assembled` only on QA-green.
`qa-deploy` is the legacy name for this same act.

## Scope

Steffon owns release stages 1-3:

1. Testing
2. Assembling
3. Deploying QA / Live on QA

This SOP stops at the Steffon -> Avi handoff: the release candidate is live on
QA and ready for Avi's production-deploy act. It does not ship production.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Shift lease — acquire the `steffon` shift FIRST, or stand down

Before preparing anything, take the DevOps shift lease so two `qa-release` sessions
can't both merge onto `release` and race the candidate N-behind (the parallel-
conductor bug):

```bash
bin/devops-shift acquire steffon
```

- **Exit 0 (acquired)** — you're on shift; continue.
- **Exit 10 ("🛑 … STAND DOWN")** — another live `steffon` session already holds the
  shift. **Do NOT merge, deploy QA, or flip stages.** Announce the holder it names
  and STOP; its lease lapses ~120s after it stops if it truly died.

The status line renews the lease automatically. Release it when the sweep is done
(or you stop early) so the lane frees immediately:

```bash
bin/devops-shift release steffon
```

(The `steffon` lane is independent of the `avi` review/ship lane, so a `qa-release`
and a `pr-review` run side by side — only two of the SAME role collide.)

## Preconditions

There is work to prepare:

- `reviewed` tasks waiting to ride the next release candidate
- `assembled` stragglers not riding the current candidate
- an interrupted release candidate already in flight

If nothing is waiting and no candidate is in flight, report "nothing to prepare"
and stop.

## Procedure

**Direct-drive this act — do NOT delegate it to a subagent.** Run
`bin/release prepare --yes` in the conductor session itself. Do NOT wrap it in an
Agent-tool subagent (`subagent_type: steffon`) for sub-agent-tree visibility.

- **The rule.** Any op that MUTATES shared state across many minutes —
  `qa-release`, `production-deploy`, `archive-shipped` — is DIRECT-DRIVEN by the
  conductor session, never handed to an ephemeral subagent. Subagents stay
  first-class for **read** fan-out (reviews, audits, searches, exploration), where
  a detach costs a retry rather than a half-applied mutation. Parallel fan-out is
  still the default for devops; the line is **mutating vs reading**, not *parallel
  vs serial*.
- **Why — learned the hard way (2026-07-11).** This SOP once told you to summon
  the sweep as a Steffon subagent. That subagent DETACHED mid-sweep and left a
  **partial release candidate**: one PR merged onto `release`, but nothing gated,
  deployed, or assembled, and no attached terminal to notice or finish it. The
  candidate just sat there. `production-deploy` was already direct-drive for
  exactly this reason; the lesson generalizes to every long mutation.
- **Visibility is not a reason to delegate.** The durable, full-visibility surface
  is the Activities timeline — narrate the act there
  (`bin/agent-activity start/next/end`). The sub-agent tree is ephemeral (it dies
  with the session) and the autonomous heartbeat has no terminal, so it renders no
  tree at all.

Normalize any PR the sweep should carry: `gh pr ready <n>` un-drafts it and
`gh pr edit <n> --base release` retargets a mis-based PR (a no-op when the base
is already `release`).

Run the self-healing prepare sweep:

```bash
bin/release prepare --yes
```

`prepare` owns the whole QA-release act:

1. Detect every `reviewed` task plus any `assembled` straggler.
2. Open or resume the release candidate.
3. Merge each task's PR onto `release`, skipping work already stamped
   `merged: release` or `merged: main`.
4. Run the pre-QA gate on `origin/release`. The suite runs in the repo's
   **isolated gate workspace** — a private detached worktree at
   `<repo>/.worktrees/_gate`, under its own lock, with a test DB the gate proves
   is private. It does NOT touch the primary checkout, which stays on a clean
   `main`. On green it RECORDS what it certified (SHA + command), which is the
   only thing the G4 ship gate will accept as grounds to skip its own suite.
   A red gate, and what to do about it (hint: **do not** blank the registry's
   `qa_test_cmd` — that silently disarms the production gate):
   [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md).
5. Deploy QA and wait for boot.
6. Flip members from `reviewed` to `assembled` only after QA is green.

`prepare` also narrates the release's **stage timeline** as it goes — its
conductor checkpoints (`assemble_release started/completed`, `deploy_qa
started/completed`, `qa_smoke started/completed`) stamp the release's stage
timestamps, which drive the /deployments tracker live: Assembling yellow →
Assembled green → Deploying QA yellow → **Live on QA** green. (Node 1 Testing
greens on its own the instant your first sweep stamps `assembling` — the
candidate doesn't exist before qa-release opens it, so nothing lights it
earlier.) You post nothing extra on the happy path.

`prepare` records its test verdicts as the **G3 Candidate gate**
([`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md)):
it opens the release's `g3_candidate` attempt (actor `steffon`) before the
pre-QA gate, collects every test SOP in the window (`pre_qa_gate` per app,
`qa_up_smoke` boot polls, `qa_post_deploy` hooks), and closes it `success`
beside the QA-green flip — or `failed` on a boot failure or any in-window
abort. Attempt-aware: a re-run opens attempt n+1, so repeated QA failures show
as a `×n` badge on the /deployments **G3 Candidate** column (which replaced
the old `review_tests`-bracketed "Tested" column). All gate writes are
best-effort and automatic — post nothing by hand.

Smoke QA after prepare reports success:

```bash
curl -fsS https://qa.mcritchie.studio/up
```

If a run was interrupted and a stage boundary went unrecorded, backfill it via
the release events API (`docs/agents/modules/task-board-api.md`, "Release stage
timeline") — e.g. `POST /api/v1/releases/current/events/qa_deploying/complete`
once QA is verifiably live. Stamps are first-write-wins, so a re-post is a safe
no-op.

If the pre-QA gate identifies an offender, eject that task instead of forcing the
candidate forward:

```bash
bin/release eject <task> --feedback "<specific failing evidence>"
```

Then re-run `bin/release prepare --yes` so the rest of the candidate can ride.

## Recovery — `prepare` is SELF-HEALING, and re-running it is SAFE

**If a sweep is interrupted — a detached agent, a killed terminal, a timeout, a
crash, a red QA — the recovery is to RE-RUN `bin/release prepare --yes`.** That is
the whole fix. Do not hand-merge, do not hand-flip stages, and above all do not
leave a half-finished candidate sitting because you are unsure whether a re-run
would double-merge. It will not:

- **Already-merged PRs are skipped.** The sweep skips any task already stamped
  `merged: release` or `merged: main` — the merge step is crash-recovery-aware, so
  a PR that landed before the interruption is never re-merged.
- **Members flip only on QA-green.** An interrupted or red run leaves them
  `reviewed`, which is exactly the state the next run detects and finishes.
- **A re-run resumes the candidate**; it does not open a second one.
- **Stage stamps are first-write-wins**, so re-posted timeline boundaries are safe
  no-ops (see the backfill note above).

### Detecting a PARTIAL release candidate

A partial RC is a candidate whose members are **merged but never assembled** — the
sweep merged the PR (step 3) and then died before the pre-QA gate, the QA deploy,
or the `assembled` flip (step 6). Nothing is corrupt, but nothing is finished, and
it is invisible unless you look for it:

```bash
bin/release status                      # current release + state
bin/task list --stage reviewed          # any of these merged onto release is a partial member
bin/task show <task> --json | jq '{stage, merged, release_slug}'
```

The smoking gun is a task stamped **`merged: "release"` while its stage is still
`reviewed`**. Compare the healthy readings:

| `stage` | `merged` | Meaning |
|---|---|---|
| `reviewed` | `null` | Waiting to be swept — normal. |
| `reviewed` | `"release"` | **PARTIAL RC — merged, never assembled. Re-run `prepare`.** |
| `assembled` | `"release"` | Healthy member, QA-green. |

On the /deployments tracker the same state reads as an **Assembling / Deploying QA
node stuck yellow** with Live on QA never greening.

Found one? Re-run `bin/release prepare --yes`.

## Exit Seam

The release candidate is `assembled` and live on QA; members are `assembled` with
`merged: release`, and the release's latest **G3 Candidate** attempt is closed
with `success`. On the /deployments tracker the release reads **three greens
(Tested · Assembled · Live on QA) with Confirming deliberately DARK** — that gap
is the handoff itself. Do NOT start or stamp `confirming`; stage 4 lights only
when Avi posts `confirming/start` as he picks the release up
(`production-deploy`). Report:

- release slug
- QA URL
- member task list
- ejected task, if any, with failing evidence
- the exact phrase "deployed to QA" for Avi's handoff

On a clean no-op, report "nothing to prepare."

## Related

- [`archive-shipped.md`](archive-shipped.md) - prior Steffon closeout act.
- [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md)
  - the G3 Candidate gate this act produces.
