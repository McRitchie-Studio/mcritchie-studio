# QA Release

## Status: Active

This is Steffon's `qa-release` SOP. It is the self-healing release prepare sweep:
detect reviewed work and release stragglers, promote `accepted → release` via ONE
batch PR per repo (review already merged each feat PR onto `accepted`), run the
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

Review has already merged each feat PR into `accepted` (stamping `merged:
"accepted"`), so the sweep no longer carries per-task feat PRs — the accepted-
ladder retarget stopgap is retired. `prepare` opens/merges ONE `accepted →
release` batch PR per repo instead.

Run the self-healing prepare sweep:

```bash
bin/release prepare --yes
```

`prepare` owns the whole QA-release act:

1. Detect every `reviewed` task plus any `assembled` straggler.
2. Open or resume the release candidate.
3. **Promote `accepted → release`**: for each repo with reviewed work, open (or
   reuse) ONE `--base release --head accepted` batch PR and merge it — landing ALL
   of `accepted` on `release` at once, not N per-task merges. Idempotent +
   fail-closed: if `accepted` is level with `release` it skips the PR but still
   records + deploys. Then record membership (re-stamping `merged: "release"`),
   skipping work already stamped `merged: release`/`main`. A `reviewed` member
   with no `merged` stamp (`merged: ""`) is a HELD anomaly — review never landed
   its feat PR on `accepted` — so it is warned and left `reviewed` (re-review to
   heal), never swept onto the RC.
4. Run the pre-QA gate on `origin/release`. **GitHub CI's conclusion for that
   exact SHA IS the verdict** (DevOps v2 Phase 3 — the local isolated-workspace
   suite is deleted at this gate; nothing runs on your machine): the gate reads
   the SHA's check-runs, **polls** a not-yet-concluded run (a just-merged tip is
   normally `pending` for a few minutes), passes on exactly one state — green —
   and fails closed on everything else. Before polling it may **credit** an
   existing green for the same commit or for the accepted head's **identical
   tree** (the live batch-PR merge re-runs a tree the accepted seam already
   greened); a credited pass names its source in the gate note and changes
   nothing else — red, pending-evidence, and diverged trees (a gem sweep's
   lock-bump commit) poll exactly as always. On green it RECORDS what it
   certified (SHA + command + CI verdict), which is the only thing the G4 ship
   gate will accept as grounds to skip its own gate. A red gate, and what to do
   about it (hint: **do not** blank the registry's `qa_test_cmd` — that silently
   disarms the production gate):
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

## Recovery — an INTERRUPTION and an ABORT need OPPOSITE responses

**Diagnose which one you have BEFORE you re-run.** `prepare` is self-healing, but
self-healing means it RESUMES work that was cut short — it does not fix work that
FAILED. A re-run skips the merges it already did and re-tests/re-deploys **the same
member code**, so re-running a red candidate goes red again, the same way, forever.

- **INTERRUPTION** — no verdict: a detached agent, a killed terminal, a timeout, a
  crash. Work is half-applied. **Re-run it.**
- **ABORT** — `prepare` reached a verdict and refused: a red pre-QA gate, a failed
  QA boot, a failed merge. **Fix the cause first, THEN re-run.**

The last run tells you which: an abort PRINTS its reason and its fix. If the sweep
simply vanished with no verdict, it was interrupted.

### INTERRUPTION — re-run `bin/release prepare --yes`. That is the whole fix.

Do not hand-merge, do not hand-flip stages, and above all do not leave a
half-finished candidate sitting because you are unsure whether a re-run would
double-merge. It will not:

- **Already-promoted work is skipped.** The sweep skips re-promoting any task
  already stamped `merged: release` or `merged: main`, and the `accepted → release`
  promote is crash-recovery-aware (idempotent: `accepted` level with `release` →
  skip the PR), so work that landed before the interruption is never re-merged.
- **An interrupted run leaves members `reviewed`** (the flip lands only on
  QA-green), which is exactly the state the next run detects and finishes.
- **A re-run resumes the candidate**; it does not open a second one.
- **Stage stamps are first-write-wins**, so re-posted timeline boundaries are safe
  no-ops (see the backfill note above).

### ABORT — fix the cause, THEN re-run

An abort leaves members `reviewed` (+ `merged: release`) and the release NOT
assembled — the same board state an interruption leaves, which is exactly why you
must not reflexively re-run. Each abort names its own case and its own fix:

| Abort | Fix FIRST | Then |
|---|---|---|
| **Pre-QA gate red — a member REGRESSION** | `bin/release eject <task> --feedback "<failing evidence>"`, then revert its merge commit on `release` (the abort prints the guidance) — as the eject step above says | re-run `prepare`; the rest of the RC rides |
| **Pre-QA gate red — ENV/toolchain** (unsatisfied bundle, Postgres down, Ruby divergence) | **Nothing to eject or revert.** Fix the environment exactly as the abort names it | re-run `prepare` |
| **QA deploy / boot FAILED** | Fix the boot failure (the summary prints the `bin/qa-server deploy …` retry); eject the member if it is the cause | re-run `prepare` **once QA boots** |
| **`accepted → release` promote failed** (a conflict on the batch PR) | Resolve the conflict on the batch PR (or `bin/task block` the offending member) | re-run `prepare` |
| **Member left `reviewed` with `merged: ""`** (review never landed its feat PR on `accepted`) | Re-review the task so `pr-review` merges it onto `accepted` | re-run `prepare` |

`prepare` never force-ships a red candidate. The only ways past a real regression
are to eject it or to fix it forward — never to re-run harder.

### Detecting an UNFINISHED release candidate

An unfinished RC is a candidate whose members are **merged but never assembled** —
the sweep promoted `accepted → release` (step 3) but never reached the `assembled`
flip (step 6).
Nothing is corrupt, but nothing is finished, and it is invisible unless you look:

```bash
bin/release status                      # current release + state
bin/task list --stage reviewed          # any of these merged onto release is an unfinished member
bin/task show <task> --json | jq '{stage, merged, release_slug}'
```

The smoking gun is a task stamped **`merged: "release"` while its stage is still
`reviewed`**. Compare the healthy readings:

| `stage` | `merged` | Meaning |
|---|---|---|
| `reviewed` | `null` | Waiting to be swept — normal. |
| `reviewed` | `"release"` | **UNFINISHED — merged, never assembled. Diagnose before re-running.** |
| `assembled` | `"release"` | Healthy member, QA-green. |

On the /deployments tracker the same state reads as an **Assembling / Deploying QA
node stuck yellow** with Live on QA never greening.

⚠️ **This board state does NOT tell you WHY, and the two causes need opposite
responses.** An INTERRUPTED sweep and an ABORTED (red) sweep leave the *identical*
`reviewed` + `merged: "release"` reading. Do not re-run on the strength of this
table alone — establish which one it is:

- **The release's latest G3 Candidate attempt** (the /deployments **G3 Candidate**
  column) — closed `failed` means the sweep reached a verdict and refused: an
  **ABORT**. Still open with no verdict means it died mid-flight: an
  **INTERRUPTION**.
- **The last run's output**, if you still have it — an abort printed its reason and
  its fix; an interruption printed nothing.

Then take the matching recovery above: interruption → re-run; abort → fix the
cause, then re-run.

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
