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

> **DevOps v2 Phase 3 (LIVE): the G3 verdict is GitHub CI**, not a local suite — see
> [The G3 verdict](#the-g3-verdict-github-ci-on-the-release-sha-devops-v2-phase-3--live)
> below. The registry/tier detail in this section describes the `qa_test_cmd` that is
> still **recorded** on the release (the G4 drift check needs it); its **execution** in
> an isolated gate workspace is demoted (commented out in `bin/release.rb`, deleted in
> Phase 4). Read the workspace/DB-probe/bundle-guard machinery below as the pre-v2
> pre-flight that is retained but no longer run.

The gate window spans prepare's whole test-and-deploy half, and every test SOP
run inside it rides the close:

- **Pre-QA suite** (`pre_qa_gate` SOPs, one per app) — each app's registered
  `qa_test_cmd` (`config/release_repos.yml`) runs against `origin/release`
  BEFORE any QA deploy. This is the tier prepare owns
  (`Release::STEP_TEST_TIERS`: `prepare → integration + e2e-smoke`):
  The split is **not** "hub vs satellite" — it is **"does this repo's DEPLOY run
  the suite?"**:
  - the **hub** registers CI's FULL suite, verbatim (`bin/rails db:test:prepare
    test test:system` — the base tier AND the **system** tier) — the batch
    certification that lets [G4 Ship](g4-ship.md) self-gate an unchanged SHA.
    It runs what CI runs by construction: `repos_test.rb` parses
    `.github/workflows/ci.yml` and asserts the two commands match, so the gate
    cannot drift out from under CI. (It once did: the gate ran `bin/rails test`,
    which SKIPS `test/system`, so a system-test regression reached QA ungated.)
    **Keep `db:test:prepare` FIRST** — `test` is a real rails command, so
    `bin/rails test test:system` parses `test:system` as a *path* and dies with
    `LoadError`; the leading non-command routes the line through rake, where the
    two tiers are separate tasks;
  - **rolio** registers CI's FULL suite too, verbatim, and for the same reason:
    it deploys via `git_push_heroku`, which runs **no tests**, so its registered
    command is the **last gate before rolio production**. It once registered
    `bin/rails test` (G4) and the integration subset (G3), **both of which skip
    `test/system`** — so rolio's system tier could regress into prod ungated.
    `repos_test.rb` parses **rolio's own** `.github/workflows/ci.yml` (read from
    `origin/release`, not the working tree) and asserts the command matches it;
  - **turf-monster** registers the integration subset (`bin/rails test
    test/integration`) — its `bin/deploy` runs the full suite pre-prod, so G3
    would only double-test. (It has no `test/system/` at all, so there is no
    system tier to cover — pinned by a test, so growing one re-opens the question);
  - an app with **no `qa_test_cmd` self-gates** and is skipped here.

  The system tier needs no setup step in the gate's virgin worktree, though the
  reason is **per-app** — do not carry one app's mechanism to the other. The
  **hub** self-heals: `rails test`/`rails test:system` each run rake
  `test:prepare`, which tailwindcss-rails enhances with `tailwindcss:build`, so
  the gitignored `app/assets/builds/tailwind.css` is built on demand. **Rolio**
  needs no build at all: it is sprockets + importmap and leaves
  `config.assets.compile` at its default `true` in test, so its stylesheets
  compile at request time from tracked sources. In both, Selenium Manager fetches
  a chromedriver matched to the installed Chrome; a host with **no Chrome** fails
  at driver resolution — an **ENV error, NOT a release regression**: nothing to
  eject or revert (`assert_system_test_browser!` aborts up front so it can't be
  mistaken for one).

  **⚠ A gate is only as trustworthy as the suite it runs — and the suite must be
  sized for THIS host.** Rolio's system tier was driven in its isolated gate
  workspace *before* being registered, and it came back **red on green code**: its
  Capybara wait budget was the 2s gem default, calibrated for an idle CI runner,
  while this gate runs on a **shared dev Mac** where the browser stack measured
  **~18x slower** under concurrent-agent load (4.6s idle → 85s loaded). Rolio's
  gate is therefore safe only behind the wait-budget fix that sizes its suite
  for the slow host: rolio task `size-rolio-system-wait-budget`
  (amcritchie/rolio#23) is a **sequenced prerequisite** — the sweep lands it
  into rolio's `release` **first**, so this widened gate never drives a
  2s-budget suite. Widening a gate onto a suite you have not driven **here** is how
  a gate starts false-failing green code — and a red release gate hands out
  **eject/revert guidance**, bouncing a good PR out of the RC.
- **QA boot smokes** (`qa_up_smoke` SOPs) — after each QA deploy, poll
  `<qa_url>/up` until 200 (the e2e-smoke half of prepare's tier; the booted
  QA deploy IS the smoke).
- **Post-deploy hooks** (`qa_post_deploy` SOPs) — each member's declared
  `devops.post_deploy_cmd` runs against its QA app; a non-zero exit aborts
  prepare.
- **The CI verdict** — GitHub CI's conclusion for the release SHA **IS** the G3
  verdict (DevOps v2 Phase 3): green certifies, every other state fails closed. The
  verdict is recorded on the release (`qa_gates[repo]`). See
  [The G3 verdict](#the-g3-verdict-github-ci-on-the-release-sha-devops-v2-phase-3--live)
  below.
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
SHA under test, with its **own test database** (`<repo>_gate_test` for a postgres
app; for a SQLite app such as rolio, the test file already lives inside the
worktree). The primary checkout is **never** flipped to `release` — it stays on a
clean `main`.

Because that worktree is created `--detach`, it does **not** carry gitignored
files — it is **virgin**. So the gate **prepares the test env** in it before
running your command: `bin/rails db:test:prepare test:prepare`, in one boot. The
`test:prepare` half is load-bearing and is why **any registered command shape is
safe** — Rails runs that hook (the one `tailwindcss-rails` enhances to build the
gitignored `app/assets/builds/tailwind.css`) *only* when no argument looks like a
**path**. The satellites register a path-arg lane (`bin/rails test
test/integration`), so Rails skipped it, so the stylesheet was never built, so
every view-rendering test died with `The asset "tailwind.css" is not present in
the asset pipeline` — **the gate went red on green code and handed out
eject/revert guidance** (2026-07-12; the same false-red class that nearly ejected
PR #498). A failed prepare now aborts as **env**, never as a red suite.

Two further things make that isolation real rather than aspirational, and both
exist because the first cut of this gate got them wrong:

* **The gate holds its OWN lock** (`mcr-gate-workspace-<repo>.lock`, *not* the
  primary-checkout lock, which stays free). The workspace is private to the
  **conductor**, not to a *process*: its path and DB are FIXED, so a second
  `bin/release` — and two QA-release sessions have raced here before — would
  `reset --hard` the tree and `db:test:prepare`-**purge** the DB under the first
  one's live suite. That is the same two root causes relocated one directory over.
  The lock is held across pin → prepare → suite; a second conductor **queues**.
* **The private DB is ASSERTED, not assumed.** Before running anything, the gate
  boots the app in the workspace and reads back the database it *actually*
  connected to (`assert_private_gate_db!`), and **refuses to run** unless it is
  the gate's own DB (or a file inside the worktree). This is not ceremony: the
  overlay is delivered by env vars, and `TEST_DATABASE_URL` is a **hand-rolled
  seam** that only works where an app's `config/database.yml` renders
  `url: <%= ENV["TEST_DATABASE_URL"] %>`. The hub does; **turf-monster does not**
  — so that var alone was silently inert there, and the gate would have run, and
  PURGED, the *shared* `turf_monster_test`. The gate now also sets `DATABASE_URL`
  (a Rails builtin every app honours) — and then checks, because a guarantee that
  depends on every future app's config being right is a convention, not an
  invariant. A shared DB is a hard abort, never a silent stomp.

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

## The G3 verdict: GitHub CI on the release SHA (DevOps v2 Phase 3 — LIVE)

**GitHub CI's conclusion for the release SHA IS the G3 verdict.** For each app the
gate resolves `origin/release`, asks GitHub what CI made of **that exact commit**
(`CiStatus.for_sha` → `gh api repos/{owner}/{repo}/commits/{sha}/check-runs`), and
turns the answer into the gate result via `ci_pass?`: **green certifies; every
other state fails closed.** `ci.yml` triggers on `push:[main, release]`, so the
merge commit the sweep produces earns its own clean-env verdict — the exact
artifact QA deploys — instead of relying on a local gate no independent lane checks.

This **inverts** the pre-v2 model, in which a *local* suite ran in an isolated gate
workspace and CI was only an *auditor* that could alarm but never block. That local
suite is now **demoted** (`bin/release.rb`: the `run_test_scope("pre_qa_gate")`
execution is commented out, retained for the canary/rollback window; Phase 4 deletes
it). The whole local-cert flakiness class — a lazily-autoloaded suite torn by a
concurrent checkout — retires with it, and the async-poll objection to *blocking* on
CI is answered by the conductor **watching** the run (`gh run watch`) instead of a
local gate polling GitHub for minutes.

> **Retained-but-demoted machinery.** The isolated-workspace apparatus described
> below (the private-DB probe, the bundle guard, the gate workspace, and the
> "reproduce in the gate workspace" advice) still lives in `bin/release.rb`, but the
> gate no longer runs it. Those paragraphs describe the pre-v2 pre-flight and are
> kept for the rollback window; Phase 4 removes them with the code. The **cmd** each
> app registers is still recorded on the release (`qa_gates[repo]["cmd"]`) so the G4
> ship gate's drift assertion holds — only its *execution* moved to CI.

**No green CI verdict FAILS CLOSED — the single most important invariant.** The gate
certifies on **exactly one** state (`green`) and holds/aborts on every other. A false
green here deploys an **untested** SHA to QA, so an absent, pending, or unreadable
verdict must **never** read as a pass:

| State | Means | G3 result |
|-------|-------|-----------|
| `green` | Every check-run passed/skipped for this SHA. | **PASS** — certify, record `ok:true`, QA deploys. |
| `red` | A check failed/cancelled. | **FAIL** — a regression is riding `release`: eject the offender, revert, re-`prepare`. |
| `none` | No check-run for this SHA. `ci.yml` triggers on `pull_request` + `push:[main, release]`, so a pushed `release` tip normally DOES build — `none` means a SHA never reached GitHub (a non-GitHub remote reads as `unverified`). | **HOLD** — wait for CI, then re-`prepare`. |
| `pending` | The push-triggered run has not settled — prepare gates seconds after the merge. | **HOLD** — wait for CI to conclude. |
| `unverified` | No `gh`, no network, a 404, a non-GitHub remote. | **HOLD** — no readable verdict, so no certification. |
| `unreadable` | **The API refused the read** (401/403) — CI may well be green; this client cannot read it. | **HOLD** — a credential fault, not a missing CI; fix the token, then re-run. |

Every non-green row records `ok:false` (a red G3 is stamped *failed*, never silently
un-recorded) and does not certify. The gate never trades a green for silence.

**`unreadable` is not `unverified`, and the difference is the point** — both fail
closed, but the operator's next move differs. `none`/`pending`/`unverified` mean *the
world has nothing to say yet* — the fix is to wait. `unreadable`
means *the world has plenty to say and this token may not hear it* — waiting is
futile and the fix is credentials, permissions, or API-limit recovery. A plain
403 does not prove a missing scope, so the gate does not prescribe one unless
GitHub identifies a permission denial. Collapsing the two was a real bug (task
`dor-check-misses-rolio-ci`, 2026-07-13): a fine-grained PAT with no `Checks:
Read` on the private `rolio` repo made every rolio CI read a bare `UNVERIFIED`,
so `bin/dor-check` denied the fast-cert route to every rolio task **and told the
builder to "push the branch and open the PR"** for a PR that was already open and
already green. A gate that cannot see must name *why* it cannot see; a gate that
lies gets routed around, and a gate nobody reads is how a genuinely RED CI ships.

**There is no local-vs-CI disagreement to arbitrate any more — CI *is* the
verdict.** The two asymmetric cases the pre-v2 auditor once drew are settled by the
inversion:

- **CI RED** → a regression is riding `release`. CI saw it — including the browser
  `test:system` lane no local gate ran (the #1 blocker class) — and the gate **fails
  closed**: QA does not deploy. Read the failing check, eject the offender
  (`bin/release eject <task> --feedback "…"`), revert its merge commit, and
  re-`prepare`; the sweep self-heals and the rest of the RC rides on. G4 no longer
  "fails open and re-runs a local suite" — it reads CI on the frozen SHA too, and a
  red SHA never reaches it because a red G3 aborts `prepare` first.
- **CI not green (`none`/`pending`/`unverified`/`unreadable`)** → the gate **holds**.
  It never trades a green for silence, and it never certifies a SHA GitHub has not
  vouched for. Wait for CI to conclude (or fix the token for `unreadable`), then
  re-`prepare`.

The verdict is recorded (see [Certification](#certification-what-g4-reads)) so it is
auditable after the run instead of scrolling past in a terminal. The old "promote the
auditor to a blocker" decision is **done** — this slice *is* that promotion.

`RELEASE_CI_STATUS` injects a canned verdict (a bare token, or a raw check-runs
payload) — the test seam; it also short-circuits the network.

## A red gate — what to do (and what NOT to do)

**Start from: CI is right.** The G3 verdict is GitHub CI's conclusion for the
release SHA — run in a clean CI environment on the exact commit, including the
browser `test:system` lane no local gate ran. A red CI is a regression until you
have evidence otherwise.

1. **Read the failing check.** `bin/release prepare` names CI's red verdict and the
   failing check(s) for the SHA. That is the regression to chase.
2. **Eject the offender** (`bin/release eject <task> --feedback "…"`), revert its
   merge commit on `release`, and re-run `bin/release prepare` — the sweep
   self-heals and the rest of the RC rides on.
3. **A `hold` is not a red.** `none`/`pending`/`unverified`/`unreadable` is CI
   without a green verdict *yet*, not a regression: wait for the run to conclude
   (or, for `unreadable`, fix the token the abort names), then re-`prepare`. The
   gate holds rather than certify blind.
4. **Never blank `qa_test_cmd`/`test_cmd` to get past it.** That old recipe silently
   disarmed the G4 production gate, and it still does not work: `ship_gate_skip?`
   returns false on a blank `cmd`, so a blanked registry fails G4's CI read closed
   too. The supported override is ship-side, explicit, and loud: `bin/release ship
   --skip-test-gate --reason "…"`, which confirms and records a **red**
   `ship_test_gate` gate SOP on the release.

> **Pre-v2 red-gate playbook (demoted).** Before Phase 3 a *local* suite was the
> verdict, so a red gate could be an env fault (the private-DB probe, the bundle
> guard, a virgin-workspace stylesheet) rather than a regression, and the move was to
> reproduce it in the gate workspace (`cd <repo>/.worktrees/_gate && bin/rails test`).
> With CI as the verdict that whole env class moves to the CI runner; the
> reproduction path is retained in `bin/release.rb` for the rollback window and
> deleted in Phase 4.

## Certification (what G4 reads)

On **every** verdict the gate stamps what CI concluded onto the release:
`metadata["qa_gates"][repo] = {"sha", "cmd", "ok", "ci" => {"state", "checks",
"count", "reason"}}`. `ok` is `true` on a green CI verdict and **`false` on a
non-green one** — a red G3 is recorded *failed*, never silently un-stamped. The
`cmd` is recorded on every verdict: it is no longer executed here, but the G4 drift
assertion (`certified_cmd == cmd && certified_sha == sha`) still needs it, so it must
never be blank. The `ci` sub-keys beyond `state` appear only when GitHub gave them.

A green `ok:true` record is the **only** grounds on which [G4 Ship](g4-ship.md) may
skip its own gate (`Release::ShipSequence.ship_gate_skip?`). Anything else — an
`ok:false` record, a different `cmd`/`sha`, or no record — makes G4 **re-derive the
verdict from GitHub CI on the frozen SHA**, fail-closed. G4 no longer re-runs a local
suite; the demoted-suite framing of the pre-v2 doc is gone.

- `"state" => "red"` in a green-looking record → `ship_gate_skip?` returns **false**:
  G4 does not self-skip and re-reads CI on the frozen SHA. In Phase 3 this is
  **defensive** — a red CI aborts `prepare` before it can ever produce a green
  `ok:true` stamp — but a stale or hand-built record carrying that shape must still be
  re-gated, never trusted.
- **No `ci` key, or a green `ok:true` record, self-skips.** The green verdict is what
  G4 trusts; a release recorded before the auditor landed carries no `ci` key and
  self-gates on its green `ok` exactly as before.
- **G4 is itself fail-closed on the frozen SHA.** The pre-v2 "fail-open only, never
  fail-closed" rule applied to the *auditor* beside a local suite; now that CI is the
  verdict at G4 too, a non-green frozen SHA fails the ship gate closed (see
  [G4 Ship](g4-ship.md)).

## Related

- [`../../agents/steffon/sops/qa-release.md`](../../agents/steffon/sops/qa-release.md)
  — the owning SOP; run that end-to-end, this doc explains the gate it
  produces.
- [`g4-ship.md`](g4-ship.md) — the next gate; its frozen-SHA test gate skips only
  against the verdict this gate RECORDED (never the registry, never the deployed
  SHA).
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface (the conductor writes through the model funnel server-side).
