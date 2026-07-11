# PR Review

## Status: Active

This is Avi's `pr-review` SOP. It reviews all submitted PRs in bounded waves and
stops approved work at `reviewed`. Steffon's `qa-release` sweep owns the merge.

## Scope

Avi owns review delegation and product acceptance. This SOP does not merge PRs,
deploy QA, ship production, or archive work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

At least one task is in `submitted`. If the queue is empty, report "no submitted
PRs" and stop.

## The 3-level hierarchy — Avi is the SUPERVISOR, never a reviewer

Review runs in three levels; keep them distinct:

1. **Session Pokémon** (identity) — the base session driving the cycle.
2. **Avi (SUPERVISOR)** — the **thin gate + orchestration**. Avi confirms
   product-acceptance, selects the reviewer pair, spawns **both** reviewers in
   parallel, collects both verdicts, and gates the task. **Avi never reviews the
   code himself.**
3. **Domain experts** (Carl · Shannon · Jasper · Steffon · Alex) — the actual
   reviewers. One is the **PRIMARY** (deep review, runs
   [`pr-review-primary.md`](pr-review-primary.md)); one is the **LIGHT** (focused
   second read, runs [`pr-review-light.md`](pr-review-light.md)). They are
   **siblings under Avi**, spawned **in parallel** — the primary does **not**
   spawn its sibling.

## Procedure

**Summon this act as an Avi supervisor subagent (interactive tree visibility).**
When a session drives a devops cycle interactively (a terminal is attached),
summon this act as its OWNING SOUL instead of running the supervisor bare in a
background shell: launch an **Avi** subagent via the Agent tool
(`subagent_type: avi`) to **supervise** the review — select the pair and spawn
the two experts. It renders as a live node in the Claude Code sub-agent tree, and
— because Avi spawns **both** the primary and the light experts in parallel as
his own child subagents — that Avi node NESTS the two reviewers as **sibling**
children, so the review fan-out shows up as a branch under Avi rather than a flat
wall of background shells. **Avi supervises; he does not review** — the two
experts under him are the reviewers. Feature builds already delegate through the
Agent tool this way; this extends the same pattern to the review lane.

**Emit two intent-labeled delegate actions — one per reviewer (enforced).** Avi
(the supervisor) spawns the pair with **two** Agent-tool calls, in a **single
message so they run in parallel**, and the Agent-tool `description` on each call
**is** the action label the timeline records:

- `summon primary review: <soul>` — the PRIMARY, pointed at
  [`pr-review-primary.md`](pr-review-primary.md).
- `summon light review: <soul>` — the LIGHT, pointed at
  [`pr-review-light.md`](pr-review-light.md).

Both reviewers are Avi's own children. **The primary must NOT spawn its sibling**
— if the primary summons anyone, the roles have inverted; stop and re-spawn both
from the supervisor. This is the drift the hardening closes: a live review had
Avi spawn only the primary, the primary then spawn its sibling, and the light
drive the verdict. Two supervisor-emitted, role-labeled delegate actions make the
structure legible and keep the primary from re-delegating.

- **Caveat.** The tree is a convenience, not the record of truth: it is
  ephemeral (it vanishes when the session ends) and the autonomous heartbeat
  runs with no terminal, so it renders no tree at all. The durable,
  full-visibility surface is the Activities timeline — narrate every act there
  regardless of whether a tree is showing.

**Don't touch the release timeline.** A review wave runs BEFORE the next release
candidate exists — the candidate is born when qa-release STARTS ASSEMBLING (the
sweep's `current_or_open!`), not here. Post no `testing/start`: with no active
release it now 404s, and opening one from review is exactly the empty 0-task
"Next Release" ghost that was removed. Node 1 Testing greens on its own once
qa-release's first sweep stamps `assembling` (`docs/agents/modules/task-board-api.md`,
"Release stage timeline").

Preferred supervisor path:

```bash
bin/pr-review --run --fast --max-idle-cycles 1 \
  --codex-workdir /Users/alex/projects/mcritchie-studio
```

Use `--fast` for bounded waves under the five-agent cap. The script picks newest
submitted tasks first, **checks the PR's live GitHub CI before anything else**
(builders submit without waiting for CI, so this pre-spawn check is the
authoritative CI verdict: **red** → the task is blocked back with the failing
checks named, no reviewers spawned; **pending or no checks yet** → the task
defers to a later wave; **green** → proceed), records `bin/reviewer-select`
intent, spawns the selected PRIMARY + LIGHT reviewers **in parallel**,
re-queries the board before each final decision, writes the task handoff, and
prints a retrospective. When you narrate the reviewer-select step, label it
**"select primary+light reviewers"** — never "summon Avi" (Avi is the
supervisor doing the selecting, not a reviewer being summoned).

The wave IS the task's **G2 Review gate**
([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md)):
`bin/pr-review` checks the PR's live CI pre-spawn (a red bounce records as a
failed `dor_review` gate-zero attempt with a `ci` SOP — no reviewer ran, but the
round-trip shows on the gates card), opens the two lanes (`g2a_primary` +
`g2b_light`) as the pair launches, the primary's gate-zero (`bin/dor-check
<task> --gate-role review`, strict: red AND pending both block there) opens+closes
its own `dor_review` gate, and each lane closes from its own reviewer's scout
report (`merge-ready` = passed;
a reportless lane stays in flight for the next wave). The chips render on the
task's gates card. Automatic on the supervisor path — record the markers with
`bin/gate` only on a hand-run review (the manual commands are in the gate doc).

Manual fallback:

```bash
bin/task list --stage submitted
bin/reviewer-select <task> --busy-auto
```

For each task, run the single-PR cascade from
[`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md): as the
**supervisor**, confirm product acceptance and select the reviewer pair, then
spawn **both** experts in parallel — the PRIMARY runs
[`pr-review-primary.md`](pr-review-primary.md) (deep review), the LIGHT runs
[`pr-review-light.md`](pr-review-light.md) (focused second read) — collect both
verdicts, and gate. You never review the code yourself. Keep review fan-out to
waves of five or fewer agents.

Verdicts:

- Two approvals, no blockers:

  ```bash
  bin/task move <task> reviewed
  bin/task note <task> --handoff "Avi review approved; ready for Steffon's qa-release sweep." --agent avi
  ```

- Request changes, missing metadata, red CI, merge risk, or acceptance mismatch:

  ```bash
  bin/task block <task> --kind rework --feedback "<one complete send-back>" --agent avi
  ```

  (A red CI is normally caught by the supervisor's pre-spawn check and blocked
  back automatically, with the failing checks named in the feedback.)

- Wait-for-CI or conductor-review: defer and re-query after the defer window.
  A still-running CI defers at the pre-spawn check, before any reviewer spawns.

Approved tasks stop at `reviewed` with `merged: nil`. Steffon's next
`qa-release` sweep moves them forward.

## Exit Seam

Every visible `submitted` PR is `reviewed`, `blocked`, or explicitly deferred
with a reason. Report the result per task.

## Related

- [`pr-review-slow.md`](pr-review-slow.md) - serialized version of this SOP.
- [`pr-review-primary.md`](pr-review-primary.md) - the PRIMARY (deep review) role
  SOP this supervisor spawns.
- [`pr-review-light.md`](pr-review-light.md) - the LIGHT (focused second read)
  role SOP this supervisor spawns.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) -
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md) -
  the G2 Review gate this supervisor's waves produce.
