# QA Release

## Status: Active

This is Avi's `qa-release` SOP. It is the self-healing release prepare sweep:
detect reviewed work and release stragglers, promote `accepted → release` via ONE
batch PR per repo (review already merged each feat PR onto `accepted`), publish
gem members + bump consumer locks (producer-first, before anything tests or
deploys), run the pre-QA gate, deploy QA, and flip members to `assembled` only on
QA-green. `qa-deploy` is the legacy name for this same act.

## Scope

Avi owns release stages 1-3 as the **assembler** (`ReleaseConductorClaim` role
`assembler`):

1. Testing
2. Assembling
3. Deploying QA / Live on QA

This SOP stops at the Avi -> Steffon handoff: the release candidate is live on
QA and ready for Steffon's `production-deploy` (deployer) act. It does not ship
production.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Assembler claim — automatic, on the RELEASE record

The lock that stops two `qa-release` sessions from both merging onto `release` and
racing the candidate N-behind (the parallel-conductor bug) now lives on the RELEASE
RECORD, not on a per-role `steffon` shift. **`bin/release prepare` takes it for you** —
the per-release `assembler` conductor claim (`ReleaseConductorClaim`) — BEFORE the
irreversible `accepted → release` promote, over the fast HTTP claim path, spawns a
detached renewer for the sweep's whole life, and releases it on completion. There is
**no `bin/devops-shift acquire steffon` step any more.**

What you will see when a second session is already assembling:

- **Stand down** — `bin/release prepare` prints `🛑 <release> assembler already held —
  STAND DOWN`, names the holder, and **aborts (exit non-zero) before anything merges or
  deploys**. Announce the holder and STOP; its lease lapses ~120s after that session
  stops if it truly died, and a re-run then resumes.
- **Resume** — if YOUR OWN earlier prepare was interrupted, re-running `bin/release
  prepare` re-acquires the same claim (same session + nonce = a no-op renew) and picks
  up where it left off.
- **Fail-open** — a claim-transport hiccup never wedges the sweep; `bin/release`
  proceeds unclaimed rather than blocking on telemetry.

Because the lock is on the release record (which turns over each release), a stale or
ghost claim can never strand the whole qa-release lane again — the failure the old
`steffon` shift lease could suffer. (Background — not needed to execute: the design is
`docs/agents/system/devops-shift-lease.md`, section B.)

## Preconditions

There is work to prepare:

- `reviewed` tasks waiting to ride the next release candidate
- `assembled` stragglers not riding the current candidate
- an interrupted release candidate already in flight

If nothing is waiting and no candidate is in flight, report "nothing to prepare"
and stop.

## Disposition — which applications ride this candidate (Avi curates)

**The default is to ship ALL reviewed work.** `bin/release prepare` sweeps EVERY
`reviewed` task (+ any `assembled` straggler) across every application and opens
ONE `accepted → release` batch PR per repo. On the happy path you take the whole
reviewed queue and this step is a no-op — do not hold work back without a reason.

**You (Avi, the assembler) decide which APPLICATIONS go in when order-of-operations
matters.** Some releases must not carry every app at once: a gem has to publish
before its consuming app can ride the bumped lock; an app depends on another app's
release landing first; a risky app should wait a cycle. In those cases curate the
candidate by APPLICATION:

- **Make the decision board-visible first.** Mark the reviewed tasks of an app you
  are holding back `included_in_release: false` (via the board, or `PATCH
  /api/v1/tasks/<slug>` with `{ "devops": { "included_in_release": false } }`).
  The reviewed-stage card then shows an amber **HELD FROM RELEASE · <app>** marker
  instead of the green **IN RELEASE**, so the disposition is legible on
  `/deployments` before anything merges. Leave the apps you ARE shipping at the
  default (unset ⇒ included ⇒ green marker).
- **Then sweep only the included apps.** Pass the tasks you ARE shipping to
  prepare: `bin/release prepare --task <slug> [--task <slug> …] --yes` sweeps just
  those (and lands ALL of `accepted` for their repos). Omit `--task` to sweep
  everything (the default).
- **Eject a member that must not ride after a candidate has formed** with
  `bin/release eject <task> --feedback "<reason>"`, then re-run `bin/release
  prepare --yes` so the rest of the candidate rides.

The `included_in_release` flag is the RECORD of your disposition (it drives the
board marker and `Task.reviewed_release_inclusion`); the `--task`/`eject` controls
are what actually shape the sweep. Keep the two in sync so the board never says
"shipping" for an app you ejected.

## Procedure

**Direct-drive this act — do NOT delegate it to a subagent.** Run
`bin/release prepare --yes` in the conductor session itself. Do NOT wrap it in an
Agent-tool subagent (`subagent_type: avi`) for sub-agent-tree visibility.

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
4. **Publish gem members + bump consumer locks — BEFORE the gate and QA**
   (producer-first, in two phases — a RubyGems push can never be re-pushed).
   Phase 1 **preflights EVERY swept gem before the first push**: a fail-closed
   fetch of `origin/release` (a stale ref must never drive an irreversible
   decision), the `version_file` parses, the **stranded-work guard** —
   `origin/release` ahead of the last published `v*` tag while the version did
   NOT advance past that tag (compared with `Gem::Version` semantics, so
   **equal, backward, and unparseable versions all block**; a backward version
   would otherwise "skip as already live" and rewrite consumers DOWNWARD into a
   production downgrade with every gate green). The fix is a version bump past
   the tag through the gem's own PR. Plus a consumer-coverage check —
   **unless the gem is self-gated** (gem-only-deployments): a gem carrying a
   `release_check` in `config/release_repos.yml` (studio-engine) is its OWN
   release candidate — its suite is the verdict and the RubyGems publish is its
   prod deploy — so it may be published with **no consuming app** in the sweep,
   and a **self-gated gem-only candidate is now allowed** (it gates at G3 on its
   own CI, step 5). A **non-self-gated** gem (solana-studio, no `release_check`)
   still requires a swept consuming app whose Gemfile declares it — a
   non-self-gated gem-only candidate, or a non-self-gated gem no swept consumer
   bundles, would assemble QA-green untested and still aborts. ANY
   failure aborts loudly with every finding named and **zero gems published**.
   Phase 2 then publishes each validated gem's `origin/release` version to
   RubyGems (skip-if-live, so re-runs are safe) and commits each consumer
   app's `Gemfile.lock` bump (`bundle lock --update <gem> --conservative`; the
   Gemfile pin is rewritten only when the new version escapes it) onto the
   consumer's `origin/release`. The pre-QA gate and the QA deploy then read
   the post-bump SHA, so QA tests the real published gem and prod ships the
   exact tree QA tested. Note: a publish is irreversible — a QA bounce can
   orphan a published version; the fix bumps past it (a dead number on
   RubyGems is harmless).
5. Run the pre-QA gate on `origin/release`. **GitHub CI's conclusion for that
   exact SHA IS the verdict** (DevOps v2 Phase 3 — the local isolated-workspace
   suite is deleted at this gate; nothing runs on your machine): the gate reads
   the SHA's check-runs, **polls** a not-yet-concluded run (a just-merged tip is
   normally `pending` for a few minutes), passes on exactly one state — green —
   and fails closed on everything else. Before polling it may **credit** an
   existing green for the same commit or for the accepted head's **identical
   tree** (the live batch-PR merge re-runs a tree the accepted seam already
   greened); a credited pass names its source in the gate note and changes
   nothing else — red, pending-evidence, and diverged trees (a gem sweep's
   lock-bump commit from step 4) poll exactly as always. On green it RECORDS
   what it certified (SHA + command + CI verdict), which is the only thing the
   G4 ship gate will accept as grounds to skip its own gate. The gate reads the
   same CI the app path does for a **self-gated gem in a gem-only release**
   (gem-only-deployments): its `accepted→release` promote PR is a `pull_request`
   run engine-ci greened, so the gem's release SHA earns the identical-tree
   credit exactly like an app, and the gate records the gem's `release_check` as
   the certified command. (A gem RIDING an app gets no extra gem gate — it is
   QA'd through its consumer.) A red gate, and
   what to do about it (hint: **do not** blank the registry's `qa_test_cmd` —
   that silently disarms the production gate):
   [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md).
6. Deploy QA and wait for boot (gem members are not QA-deployed — they were
   published at step 4 and are QA'd through the consuming app's bumped lock; a
   **gem-only release has no app QA deploy at all** — it assembles on its G3 CI
   verdict, and the /deployments board shows a **GEM-ONLY** badge with the
   published `💎 <gem> <version>` as the deployment artifact).
7. Flip members from `reviewed` to `assembled` only after QA is green.

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
it opens the release's `g3_candidate` attempt (under the assembler actor
`bin/release` records) before the
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
| **STRANDED GEM WORK** (gem `origin/release` ahead of its last `v*` tag, version not advanced past it — unbumped, BACKWARD, or unparseable) | Bump the gem's version through its own PR PAST the tag the abort names (it also names the stranded commits). A **backward** version — the abort says `DOWNGRADE` — means a version conflict was resolved the wrong way on a merge into `release`; fix the version file, don't force it through | re-run `prepare`; nothing was published or deployed |
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
flip (step 7).
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

- [`../../steffon/sops/production-deploy.md`](../../steffon/sops/production-deploy.md)
  - the Steffon deployer act this assembled candidate hands off to.
- [`../../steffon/sops/archive-shipped.md`](../../steffon/sops/archive-shipped.md)
  - Steffon's post-ship closeout act.
- [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md)
  - the G3 Candidate gate this act produces.
