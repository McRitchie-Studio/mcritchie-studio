# G3 Candidate — the release candidate's QA gate

## Status: Active

G3 Candidate is the third branded testing gate: the **release-grain**
certification (GateRun key `g3_candidate`, subject = the release slug) that the
assembled candidate on `origin/release` is **deployable and QA-green**. It is
produced by Steffon's `qa-release` act — `bin/release prepare` opens it, runs
everything inside its window, and closes it with the verdict.

The four gates in order: [G1 Cert](g1-cert.md) → [G2 Review](g2-review.md) →
**G3 Candidate** (this doc) → [G4 Ship](g4-ship.md).

## What this gate verifies

The gate window spans prepare's whole test-and-deploy half, and every test SOP
run inside it rides the close:

- **Pre-QA suite** (`pre_qa_gate` SOPs, one per app) — each app's registered
  `qa_test_cmd` (`config/release_repos.yml`) runs against `origin/release`
  BEFORE any QA deploy. This is the tier prepare owns
  (`Release::STEP_TEST_TIERS`: `prepare → integration + e2e-smoke`):
  - the **hub** registers its FULL suite (`bin/rails test`) — the batch
    certification that lets [G4 Ship](g4-ship.md) self-gate an unchanged SHA;
  - **satellites** register the integration subset
    (`bin/rails test test/integration`) — their full suite runs at ship / their
    own deploy;
  - an app with **no `qa_test_cmd` self-gates** and is skipped here.
- **QA boot smokes** (`qa_up_smoke` SOPs) — after each QA deploy, poll
  `<qa_url>/up` until 200 (the e2e-smoke half of prepare's tier; the booted
  QA deploy IS the smoke).
- **Post-deploy hooks** (`qa_post_deploy` SOPs) — each member's declared
  `devops.post_deploy_cmd` runs against its QA app; a non-zero exit aborts
  prepare.
- **The QA-green flip** — `Release::Conductor.qa_green!` flips swept members
  `reviewed → assembled` and the RC `assembling → assembled`. The gate closes
  `success` only beside that flip.

## Who runs it

**Steffon**, via the `qa-release` SOP
([`../../agents/steffon/sops/qa-release.md`](../../agents/steffon/sops/qa-release.md)).
The gate writes are conductor-owned (actor `steffon`, source `conductor`) —
you never post G3 markers by hand on the happy path.

## Procedure

From the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/release prepare --yes
```

The conductor records the gate for you:

1. **Open** — `g3_candidate` opens on the release (actor `steffon`) right
   before the pre-QA gate, so the window covers every verification prepare
   runs. Attempt-aware: a re-run after a failed attempt opens attempt n+1; an
   interrupted-but-still-open attempt is re-entered.
2. **Collect** — every `run_test_scope` inside the window (`pre_qa_gate`,
   `qa_up_smoke`, `qa_post_deploy`) appends one executed-SOP entry
   (`{sop, cmd, result, duration_ms}`); the SOPs ride the close payload in one
   write.
3. **Close** —
   - **`success`** beside the QA-green flip: every QA app booted (`/up` 200)
     AND the blocking post-deploy hooks ran green AND `qa_green!` landed.
   - **`failed`** when a QA app never returned `/up` 200 (metadata carries the
     reason; members stay `reviewed`, the RC stays `assembling`, and the next
     self-healing run picks them back up).
   - **`failed` with `metadata.aborted: true`** when anything inside the
     window aborts — a red pre-QA suite, a QA-deploy/checkout abort, a
     post-deploy hook failure. The close never masks the abort; prepare's
     eject guidance still prints.

If the pre-QA gate names an offender, eject it and re-run so the rest of the
candidate rides:

```bash
bin/release eject <task> --feedback "<specific failing evidence>"
bin/release prepare --yes
```

## Success, failure, and attempt semantics

- One GateRun attempt per prepare run that enters the window. **Retries are
  first-class**: repeated QA failures stack visible failed attempts
  (`×n` badge) instead of collapsing into one silent window.
- All gate writes are **best-effort** — a board blip warns and the deploy
  continues; a gate write never aborts a prepare.
- `--dry-run` suppresses every gate write (the plan still prints).

## UI surfaces

- **/deployments table** — the **G3 Candidate** column
  (`Release::DEPLOYMENT_STAGES`, between Assembled and G4 Ship) is
  **gate-backed**: it renders the LATEST attempt's span — duration, fail tint
  on `success: false`, and the `×n` retry badge. This replaced the old
  `review_tests` bracket that made "Tested" start after "Assembled".
- The pizza tracker's stage stamps (`assemble_release`, `deploy_qa`,
  `qa_smoke` release events) are unchanged — gates record verdicts, stamps
  record stages.
- **CLI read:** `bin/gate show release <release-slug>` (add `--json` for raw
  attempts).

## Where the pre-QA suite runs (and why it is trustworthy)

In the repo's **isolated gate workspace** (`Release::GateWorkspace`): a private
detached git worktree at `<repo>/.worktrees/_gate`, pinned at the origin/release
SHA under test, with its **own test database** (`<repo>_gate_test`). The primary
checkout is **never** flipped to `release` — it stays on a clean `main`.

This is what makes a red gate *mean* something. The gate used to run its
multi-minute suite on the SHARED primary, and the test env autoloads **lazily**
(`config.eager_load = ENV["CI"].present?` — false locally, true on CI). So any
concurrent `git checkout` in the primary — another agent session, a hand-run
command; the primary-checkout `flock` is advisory and binds only other
`bin/release` invocations — tore the code snapshot **mid-suite**: test files
already loaded from `release`, models autoloaded minutes later from `main`. The
gate then false-failed on genuinely green code (rel-20260711-7f2913: three false
alarms in one release; a reviewer nearly ejected a good PR). The shared test DB
was the same bug in a second dimension. A private tree and a private DB close
both. (Bootsnap was the prime suspect and is **innocent** — verified by
experiment; its cache keys on mtime+size and `git checkout` bumps mtime.)

The gate's spawn env (`Release::GateEnv`) also **unsets**
`CLAUDE_CODE_SESSION_ID` / `CODEX_THREAD_ID`, so the suite's subprocess-spawning
tests see the same no-session environment CI does, and pins the mise ruby.

## Certification (what G4 reads)

On GREEN, the gate stamps **what it actually certified** onto the release:
`metadata["qa_gates"][repo] = {"sha", "cmd", "ok" => true}`. That record is the
**only** grounds on which [G4 Ship](g4-ship.md) may skip its own suite. A gate
that skipped, was misconfigured, or went red leaves **no record**, so G4 fails
open and runs the suite itself — a skipped G3 can never certify a SHA.

## Related

- [`../../agents/steffon/sops/qa-release.md`](../../agents/steffon/sops/qa-release.md)
  — the owning SOP; run that end-to-end, this doc explains the gate it
  produces.
- [`g4-ship.md`](g4-ship.md) — the next gate; its frozen-SHA test gate skips only
  against the verdict this gate RECORDED (never the registry, never the deployed
  SHA).
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface (the conductor writes through the model funnel server-side).
