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

## Preconditions

There is work to prepare:

- `reviewed` tasks waiting to ride the next release candidate
- `assembled` stragglers not riding the current candidate
- an interrupted release candidate already in flight

If nothing is waiting and no candidate is in flight, report "nothing to prepare"
and stop.

## Procedure

**Summon this act as a Steffon subagent (interactive tree visibility).** When a
session drives a devops cycle interactively (a terminal is attached), summon this
act as its OWNING SOUL instead of running the sweep bare in a background shell:
launch a **Steffon** subagent via the Agent tool (`subagent_type: steffon`) and
have that subagent execute `bin/release prepare --yes` (the full procedure
below). It renders as a live node in the Claude Code sub-agent tree under the
orchestrator.

- **Caveat.** `bin/release` is a script, so the Steffon subagent is a thin driver
  around it: the tree node is real, but the sweep's subprocess internals (the
  merges, the pre-QA gate, the QA deploy) run INSIDE that agent and are not their
  own tree nodes. The tree is also ephemeral (it dies with the session) and the
  autonomous heartbeat runs with no terminal, so it renders no tree. The durable,
  full-visibility surface is the Activities timeline — narrate the act there.

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
4. Run the pre-QA gate on `origin/release`.
5. Deploy QA and wait for boot.
6. Flip members from `reviewed` to `assembled` only after QA is green.

`prepare` also narrates the release's **stage timeline** as it goes — its
conductor checkpoints (`assemble_release started/completed`, `deploy_qa
started/completed`, `qa_smoke started/completed`) stamp the release's stage
timestamps, which drive the /deployments tracker live: Assembling yellow →
Assembled green → Deploying QA yellow → **Live on QA** green. (Node 1 Testing
is lit by the review wave's `testing/start`, not by prepare.) You post nothing
extra on the happy path.

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

## Exit Seam

The release candidate is `assembled` and live on QA; members are `assembled` with
`merged: release`, and the release's latest **G3 Candidate** attempt is closed
`passed`. On the /deployments tracker the release reads **three greens
(Testing · Assembled · Live on QA) with Confirming deliberately DARK** — that gap
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
