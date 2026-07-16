# Production Deploy

## Status: Active

This is Avi's `production-deploy` SOP. It ships an assembled, QA-green release to
production when one is ready.

## Scope

Avi owns release stages 4-5:

1. Confirming
2. Deploying production

This SOP crosses the production gate. Use it only when Mr. McRitchie launched
`production-deploy` or otherwise granted production ship authority in this
session.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Shift lease — acquire the `avi` shift FIRST, or stand down

Before confirming or shipping, take the DevOps shift lease so two `avi` sessions
can't ship the same release (or a ship and a `pr-review` collide on Avi's lane):

```bash
bin/devops-shift acquire avi
```

- **Exit 0 (acquired)** — you're on shift; continue. (If this session already ran
  `pr-review` and holds `avi`, re-acquiring is a no-op renew — same live instance.)
- **Exit 10 ("🛑 … STAND DOWN")** — another live `avi` session holds the shift. **Do
  NOT confirm or ship.** Announce the holder it names and STOP; its lease lapses
  ~120s after it stops if it truly died.

The status line renews it automatically. Release it once the ship completes (or you
stop early):

```bash
bin/devops-shift release avi
```

## Preconditions

- Steffon's `qa-release` has produced a QA-green release.
- The active release is `assembled` and `qa_deployed_at` is stamped.
- Members are `assembled` and `merged: release`.
- The release candidate is live on QA.
- The primary checkout is clean enough to ship.

If `release == main`, no release is active, the active release is still
`assembling`, or `qa_deployed_at` is blank, report "nothing to ship" and stop.

## Procedure

**Direct-drive this act — do NOT wrap it in a subagent.** Run `bin/release ship
--yes` in the orchestrating session itself. Do NOT delegate it to a wrapper
subagent (`subagent_type: avi`) for sub-agent-tree visibility.

- **The rule this follows.** Any op that MUTATES shared state across many minutes
  — `production-deploy`, `qa-release`, `archive-shipped` — is DIRECT-DRIVEN by the
  conductor session, never handed to an ephemeral subagent. A subagent that dies
  mid-op (crash, timeout, killed terminal) leaves the mutation HALF-APPLIED, with
  no attached terminal to notice or finish it. Subagents stay first-class for
  **read** fan-out — `pr-review` still supervises its PRIMARY + LIGHT reviewers as
  subagents, because a detached *review* costs a retry, not a broken release. The
  line is **mutating vs reading**, not *parallel vs serial*.
- **Why the ship especially.** This is the one IRREVERSIBLE gate. An orphaned ship
  leaves a partial `release → main` state that nobody owns. The same failure hit
  `qa-release` on 2026-07-11 while it was still delegated: the Steffon subagent
  detached mid-sweep and left a partial release candidate — merged onto `release`,
  but never gated, deployed, or assembled — and it sat there unnoticed.
- **Recovery from an INTERRUPTED ship: re-run `bin/release ship --yes`.** It is
  idempotent and resumes. A partial ship aborts on the first failure and runs the
  record step LAST, so it leaves the release `assembled` — the recoverable state a
  re-run picks up. On that re-run, repos already stamped `merged: "main"` are
  skipped for re-ff (the git-location crash-recovery signal), published gems skip,
  the fast-forwards are git no-ops, and Gemfile re-pins are idempotent. **But only
  a live terminal can re-run it** — which is exactly why this act is never handed
  to an agent that can vanish.
- **Visibility is not a reason to delegate.** The durable record is the Activities
  timeline and the release's stage timeline, not the ephemeral sub-agent tree.

**Gate before activating Avi.** Do not post `confirming/start` just because
`Release.current` exists. The Avi handoff exists only when the next release is
already live on QA: `Release.current.state == "assembled"` and the
`qa_deployed_at` stage timestamp is present.

```bash
bin/release status
```

If status reports `release == main`, stop immediately. Otherwise validate the
production-board release timestamp before lighting stage 4:

```bash
heroku run -a mcritchie-studio --no-tty --exit-code rails runner \
  'r = Release.current;
   ready = r&.state == "assembled" && r.qa_deployed_at.present?;
   puts({
     ready: ready,
     release: r&.slug,
     state: r&.state,
     qa_deployed_at: r&.qa_deployed_at&.iso8601,
     qa_url: r&.qa_url
   }.to_json);
   exit(ready ? 0 : 1)'
```

If that command exits nonzero, the release is not ready for Avi. Do not stamp
`confirming/start`, do not run `bin/release ship`, and report "nothing to ship"
with the printed release state.

**Announce the handoff only after that guard passes.** The QA-green release sits
at three greens with Confirming dark — Steffon's finish line. The moment you
begin confirming, notify the release so the /deployments tracker lights stage 4
yellow under your name (`docs/agents/modules/task-board-api.md`, "Release stage
timeline"):

```bash
# api() helper + TOKEN per task-board-api.md "Worked example"
api POST /api/v1/releases/current/events/confirming/start '{"event": {"actor": "avi"}}'
```

`start` needs no usage metadata. The stamp is first-write-wins, so a re-run is a
safe no-op. (If you skip this and go straight to `bin/release ship`, its
`ship_gate started` checkpoint stamps `confirming` then — but only at ship time,
which under-reports your confirmation work; post the start when the work starts.)

Run ship only when status shows a ready QA-green release:

```bash
bin/release ship --yes
```

Ship from the primary checkout, not a feature worktree. `--yes` answers one
local guard — the pre-dispatch `confirm("Deploy this release to production?")`
that runs before any deploy — so a hands-off run opts in instead of hanging on a
prompt. It skips nothing else: the preflight, frozen-SHA test gate, gem-publish
ordering, deploy smoke, release notes, and partial-ship recovery all still run.
**`--yes` does not bypass the production approval below** — that gate lives on
GitHub, and the ship blocks on it whether or not you passed `--yes`.

**The real ship-confirm is the `production` GitHub Environment approval, not a
local prompt.** The hub deploys through GitHub Actions: `bin/release ship`
dispatches `prod-deploy.yml` (`gh workflow run prod-deploy.yml -f sha=<frozen>`)
and watches the run. That workflow is `workflow_dispatch`, and it pauses at the
`production` Environment for the operator's required-reviewer approval — the gate
that replaced the old local interactive prompt. Until the operator clicks
**Review deployments → Approve** on the run, it sits `waiting` and the ship
HOLDS on it — unbounded, however long the approval takes. So announce the paused
run and wait; do not read the block as a hang. Once approved, GitHub Actions
force-pushes the frozen SHA to Heroku `main` and hard-gates a `/up` smoke — it
retries `/up` and FAILS the deploy if production never returns 200. The watch
returns green only after that deploy-and-smoke concludes, so the hub runs no
separate local smoke.

**A dirty app primary does NOT block the ship.** The deploy runs from its own
checkout — a private detached worktree at `<repo>/.worktrees/_ship`, pinned at the
QA-frozen SHA — and advances `main` with a ref push
(`git push origin <frozen>:refs/heads/main`), which reads no working tree at all.
So a concurrent feature session's staged work in a primary is simply not the
ship's business: the preflight prints a note and deploys. (It used to REFUSE, and
that refusal once aborted a ship *after the gems had published*.) If you want a
primary clean, the preflight prints the exact rescue — commit the stranded work to
a labeled `rescue/<repo>-<timestamp>` branch. **Never stash it and never discard
it**: it may be a live session's work.

**The ship also advances `accepted`, not just `main`.** The moment `main` lands,
it re-baselines each repo's `origin/accepted` integration branch onto the same
frozen SHA (`git push origin <frozen>:refs/heads/accepted`) — feature branches
cut from `accepted`, so keeping it level with `main` stops it drifting stale
behind production. This retires the manual `git push origin
origin/main:refs/heads/accepted` chore. The advance is guarded (only where
`origin/accepted` exists), fail-closed (no `--force`; a non-fast-forward means
`accepted` diverged, so git refuses and the ship warns and moves on), and
non-fatal — it never aborts a landing deploy.

**One thing still gates on a primary: a gem repo with modified TRACKED files.**
`gem build` packages what is on disk, so those edits would be *published* — and a
RubyGems version can never be re-pushed. That aborts, before anything is
published, and prints the same labeled-branch rescue. Run it, then re-run ship.

The frozen-SHA test gate is each app's registry `test_cmd` — the **full local
suite** (`Release::STEP_TEST_TIERS`: `ship → full-suite`; it is not a browser
e2e run — browser-level verification is the post-deploy smoke seal). It runs in
the repo's **isolated gate workspace** (a private detached worktree at
`<repo>/.worktrees/_gate`, under its own lock, with a proven-private test DB) —
NOT on the primary. Nothing at all is mutated before ship authority: a red gate or
a declined confirm leaves every checkout exactly as it found it.

It **self-gates against G3**, but ONLY on G3's RECORDED verdict
(`metadata["qa_gates"][repo]`, written only after a GREEN pre-QA suite): same
command + same frozen SHA + green **+ an auditor that did not go red** ⇒ it
records a visible skip SOP instead of re-running, so the full suite runs once per
release batch.

⏱ **Everything else FAILS OPEN — the gate RUNS.** No G3 record (a G3 that was
skipped or never ran), a red record, a different command, a drifted/straggler
SHA, **or a RED auditor** (GitHub CI called that same SHA broken while G3 called
it green) all re-trigger the full suite. **Budget for it:** a ship after a
skipped, red, or CI-contradicted G3 now takes a full-suite run where it used to
skip instantly. That is deliberate — an uncertified SHA must not reach production
unchecked. Details:
[`../../../modules/gates/g4-ship.md`](../../../modules/gates/g4-ship.md).

⚠ **If the ship prints `G3 certified <sha> GREEN but GitHub CI called that SHA
RED`, STOP AND READ IT.** G3's local suite passed on that commit and GitHub CI
failed on the *same* commit. The gate is already re-running the suite for you
(the certification is distrusted) — but **do not read that re-run as a
backstop**: it re-runs the **local** `test_cmd`, the very suite that already
passed, while the failing lane is one only CI can see (the browser `test:system`
suite). **Nothing downstream will catch this for you.** You are the last gate
before production:

- Open the named check on GitHub and read the failure.
- If it is real — **do not ship.** Fix forward, or `bin/release eject <task>
  --feedback "<the failing check>"` and have Steffon re-run `bin/release
  prepare`.
- If you ship past it anyway, that is a **deliberate, unguarded call** — say so
  out loud in the handoff.
- **"no GitHub verdict for `<sha>`" is NOT this alarm.** That is the normal line
  today (CI does not build `release` yet) and means nothing is wrong.

If a ship gate is a genuine false negative, the supported override is
`bin/release ship --skip-test-gate --reason "…"` — it confirms, and records a
**red** gate SOP. **Never** blank the registry's `test_cmd`/`qa_test_cmd` to get
past a gate: that silently disarmed this gate while printing "already green".

`ship` records its verdicts as the **G4 Ship gate**
([`../../../modules/gates/g4-ship.md`](../../../modules/gates/g4-ship.md)):
it opens the release's `g4_ship` attempt at the ship gate and closes it
`success` after the deploys, `/up` smokes, post-deploy hooks, and the smoke
seal (the seal's verdict rides in the gate's `metadata.seal`; a red seal never
flips the gate's success, exactly as it never aborts the ship) — or `failed`
on any in-window abort, with the re-run opening attempt n+1. The verdict
renders as the /deployments **G4 Ship** column. All gate writes are automatic
and best-effort — post nothing by hand.

`ship` narrates the rest of the stage timeline itself (`ship_gate` →
Confirmed green, `deploy_prod started` → Deploying yellow, the ship flip →
Deployed green) — no extra posts on the happy path. The `ship_gate` /
`ship_authorized` stamps stay the tracker's node-4 confirm beat; the gate
records the verdicts, never replaces the stamps. After an interrupted run,
backfill the missed boundary via the release events API; stamps are
first-write-wins, so re-posts are safe no-ops.

The final production record step is intentionally release-first. After all
production deploys and smoke checks have passed, `bin/release ship` marks the
release itself deployed before it begins moving member tasks to `shipped`. That
release update is what turns the board's Next Release into Last Release and
fires the live Last Release freshness glow. Do not hand-run a bulk
`bin/task move ... shipped` batch: let `bin/release ship` move the member tasks
so each task transition lands one second after the prior one.

Post-ship, `bin/release ship` auto-runs the hub primary's
`bin/install-agent-docs` (non-fatal — it never aborts a completed ship;
Steffon owns the step and its mechanism) so the installed agent docs
(`~/.claude` + `~/.codex` skills, the projects-root `AGENTS.md`/`CLAUDE.md`)
match what shipped. If it warns, run the installer from the hub primary by
hand.

**An ABORT and an INTERRUPTION need OPPOSITE responses — do not confuse them.**

- **The ship gate ABORTED** — a red suite, a failed preflight, a failed deploy or
  smoke. The run reached a verdict and refused. **Do not force past it.** Record
  the blocker and hand it off.
- **The ship was INTERRUPTED** — crash, timeout, killed terminal. There is no
  verdict, just half-applied work. **Re-run `bin/release ship --yes`**; it resumes
  idempotently, per "Recovery from an INTERRUPTED ship" above.

## Exit Seam

The ready release is `shipped` and members remain stamped `merged: main`, or the
act reports a clean no-op because nothing was ready. Report:

- release slug
- production SHA
- production URL
- smoke result

On a clean no-op, report "nothing to ship."

## Related

- [`../../../modules/gates/g4-ship.md`](../../../modules/gates/g4-ship.md) -
  the G4 Ship gate this act produces.

## Background — not needed to execute

- [`../../../system/devops-cycle-design.md`](../../../system/devops-cycle-design.md)
  §1.4 - release atom model and production gate (architecture).
