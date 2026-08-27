# Production Deploy

## Status: Active

This is Steffon's `production-deploy` SOP. It ships an assembled, QA-green release
to production when one is ready.

## Scope

Steffon owns release stages 4-5 as the **deployer** (`ReleaseConductorClaim` role
`deployer`):

1. Confirming
2. Deploying production

This SOP crosses the production gate. Use it only when Mr. McRitchie launched
`production-deploy` or otherwise granted production ship authority in this
session.

## Entry

Run this SOP from the McRitchie Studio primary checkout, **under the deployer
GitHub App identity**:

```bash
cd /Users/alex/projects/mcritchie-studio
export GH_APP_ITEM=github.mcritchie-deployer
export GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | \
  /Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential get | \
  sed -n 's/^password=//p')
```

Order matters: the helper reads `GH_APP_ITEM`, so the first export is what makes
the second one mint the **deployer** token rather than the default agent one.

If a credential goes stale mid-ship, it is **yours to fix**:
`eval "$(bin/gh-auth-refresh --export)"` re-mints on **this** lane (deployer, per
the export above) — never `gh auth login`, and never an escalation to Mr.
McRitchie. Architecture and symptom→fix:
[`source-control.md`](../../../modules/source-control.md).

The two exports cover the two auth legs — they are NOT interchangeable:

- **`GH_APP_ITEM`** declares **the lane**. The global git credential helper
  (`bin/gh-app-git-credential`) reads it and mints per-push tokens for the
  ship-lane App (`github.mcritchie-deployer`: contents + actions + checks-read
  + secrets) for the `release`/`main` fast-forwards. `bin/gh-token`,
  `bin/gh-auth-refresh`, and the gates' automatic mint-and-retry (`GhAuthRetry`,
  reached from this lane only through `bin/lib/ci_status.rb`'s check-run reads)
  read it too, so a ship session's `gh` recovery stays on the deployer App
  instead of silently re-authenticating as the agent. **The two PR-WRITING
  commands are the deliberate exception**: `bin/ship` and `bin/pr-review` pin
  `identity: "agent"`, because the deployer App holds no `pull_requests` grant
  and a recovery that followed a stray lane export would mint the one App that
  cannot do the write it is recovering. Neither runs in this SOP. **`gh` still
  never consults git credential helpers** — that is why the second export
  exists.

  An `--identity` passed with an **empty** value (`--identity "$VAR"` with `VAR`
  unset) aborts rather than falling back to `agent`; omitting the flag entirely
  still resolves through `GH_APP_ITEM`.
- **`GH_TOKEN`** is what the session's `gh` calls (`gh workflow run`,
  `gh run watch`, API reads) authenticate with — a minted installation token.
  It expires in **1 hour**, and the expiry reads as **401 `Bad credentials`**,
  not a 403: the token is sent and rejected. Re-run the export to re-mint, then
  re-run the failed step. (A **403 `not accessible by personal access token`**
  is the other fault — `GH_TOKEN` unset or empty, so `gh` never sent it and fell
  back to the stored PAT. Same remedy.) Never print the token.

The deployer identity **cannot open or merge PRs by design** — that is the
point, not a bug: PR writes belong to the build/review lanes' default
`github.mcritchie-agent` identity. See
`docs/agents/modules/credentials.md` → GitHub.

Use the production board by default. Do not add `--local`.

## Deployer claim — automatic, on the RELEASE record

> **Lane name vs. owner (read this first).** The `avi` in this section is a
> historical shift-LANE key from when the ship used to be Avi's — it is NOT the
> current owner. After the 2026-07-22 reslot **Steffon owns production-deploy** (you,
> running this SOP) and **Avi owns qa-release**. The ship's `avi` shift is retired
> anyway: its lock moved to the per-release `deployer` claim described below. The only
> `avi` shift still live is `clean-up`'s board-sweep lane — a code identifier left
> unchanged. Read `avi`/`steffon` here as opaque lease names, and take the act-owner
> from the SOP that owns the act, never from the lane key.

The lock that stops two `avi` sessions from shipping the same release now lives on the
RELEASE RECORD, not on a per-role `avi` shift. **`bin/release ship` takes it for you** —
the per-release `deployer` conductor claim (`ReleaseConductorClaim`) — BEFORE the
frozen-SHA gate and any deploy mutation, over the fast HTTP claim path, spawns a
detached renewer for the ship's whole life, and releases it on completion. There is
**no `bin/devops-shift acquire avi` step for the ship any more.**

What you will see:

- **Stand down** — if another live session is already shipping this release,
  `bin/release ship` prints `🛑 <release> deployer already held — STAND DOWN`, names the
  holder, and **aborts (exit non-zero) before any deploy**. Announce the holder and
  STOP; its lease lapses ~120s after that session stops if it truly died.
- **Resume** — an INTERRUPTED ship re-run resumes: re-running `bin/release ship` from
  the same session re-acquires the same `deployer` claim (same session + nonce = a
  no-op renew), so the partial-ship recovery picks up where it left off instead of
  standing itself down.
- **Fail-open** — a claim-transport hiccup never wedges the ship; `bin/release`
  proceeds unclaimed rather than blocking on telemetry.

Because the lock is on the release record (which turns over each release), a stale or
ghost claim can never strand the ship lane again. (Background — not needed to execute:
`docs/agents/system/devops-shift-lease.md`, section B.)

> Note: `clean-up` still takes the `avi` **shift** lease (`bin/devops-shift acquire
> avi`) for its board sweep — that lane is unchanged. Only the SHIP left the shift for
> the release-record claim. The one thing the shared shift used to guarantee — that
> `clean-up` could not reclaim ship's fixed-path `_ship`/`_gate` workspaces mid-ship — is
> now enforced directly: `bin/agent-worktree` withholds `_ship`/`_gate` from reclaim
> whenever a live `deployer` claim exists (a ship in progress), so a concurrent `clean-up`
> stands down on those workspaces instead of tearing them out from under a live deploy.

## Preconditions

- Avi's `qa-release` has produced a QA-green release.
- The active release is `assembled` and `qa_deployed_at` is stamped.
- Members are `assembled` and `merged: release`.
- The release candidate is live on QA.
- The primary checkout is clean enough to ship.

If `release == main`, no release is active, the active release is still
`assembling`, or `qa_deployed_at` is blank, report "nothing to ship" and stop.

## Procedure

**Direct-drive this act — do NOT wrap it in a subagent.** Run `bin/release ship
--yes` in the orchestrating session itself. Do NOT delegate it to a wrapper
subagent (`subagent_type: steffon`) for sub-agent-tree visibility.

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

**Gate before confirming the ship.** Do not post `confirming/start` just because
`Release.current` exists. The Avi → Steffon handoff exists only when the next release is
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

If that command exits nonzero, the release is not ready to ship. Do not stamp
`confirming/start`, do not run `bin/release ship`, and report "nothing to ship"
with the printed release state.

**Announce the handoff only after that guard passes.** The QA-green release sits
at three greens with Confirming dark — Avi's assembler finish line. The moment you
begin confirming, notify the release so the /deployments tracker lights stage 4
yellow under your name (`docs/agents/modules/task-board-api.md`, "Release stage
timeline"):

```bash
# api() helper + TOKEN per task-board-api.md "Worked example"
api POST /api/v1/releases/current/events/confirming/start '{"event": {"actor": "steffon"}}'
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
**That local confirm is now the only human gate** — the ship no longer blocks on
a GitHub approval (see below).

**A GEM-ONLY release ships too** (gem-only-deployments). A release whose every
member is a self-gated gem (no app member — `Release#gem_only?`) reaches you
`assembled` just like any other, and `bin/release ship` handles it with no
special-casing: it fast-forwards each gem repo's `release → main`, re-verifies
the gem publish idempotently (already-live → skip), and stamps `merged: main` /
`shipped`. There is no app deploy — the RubyGems publish (already done at
qa-release step 4) IS the production deploy — so the /deployments board shows the
release with a **GEM-ONLY** badge and `💎 <gem> <version>` as its artifact
instead of a Prod/SHA link. Expect DIVERGED merges (the gem note below) as usual.

**The ship-confirm is launching this SOP, not a second click.** The hub deploys
through GitHub Actions: `bin/release ship` dispatches `prod-deploy.yml` (`gh
workflow run prod-deploy.yml -f sha=<frozen>`) and watches the run. That workflow
is `workflow_dispatch` into the `production` Environment, kept for
`HEROKU_API_KEY` secret scoping and the deployment history — but its
required-reviewer approval was **REMOVED on 2026-07-20** (task
`remove-prod-deploy-approval`), so the run deploys straight through with **no
manual approval click**. GitHub Actions force-pushes the frozen SHA to Heroku
`main` and hard-gates a `/up` smoke — it retries `/up` and FAILS the deploy if
production never returns 200. The watch returns green only after that
deploy-and-smoke concludes, so Actions — not a local hub curl — runs the deploy
`/up` smoke. (The post-ship `@qa-readonly` production smoke seal below still runs
locally on the hub.) The watcher still HOLDS unbounded on any live run status, so
if a protection rule is ever re-added the ship waits it out rather than failing
closed.

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
`origin/accepted` exists), fail-closed (no `--force`), and non-fatal — it never
aborts a landing deploy.

**A refused advance does NOT mean `accepted` diverged.** A non-fast-forward only
says the push was not a fast-forward; the ship classifies WHY before advising,
and prints one of three outcomes. Read the label — the right action differs:

| Outcome | What it means | What you do |
|---|---|---|
| **AHEAD** | `accepted` already contains everything that shipped and carries more — a review pass merged into `accepted` while the ship ran (a supported, normal overlap) | **Nothing.** |
| **DIVERGED** | `accepted` is genuinely missing shipped content | Reconcile with a **merge** — recipe below |
| **UNDETERMINED** | the relation could not be read | Check first (below), then act |

**Never** reconcile with a bare `git push origin <sha>:refs/heads/accepted`. On an
AHEAD `accepted` that DESTROYS the merged work — it happened on
rel-20260720-1fc111, and it is why the classification exists.

On **UNDETERMINED**, run `git -C <path> fetch origin && git -C <path> diff
origin/accepted origin/main` and read it by this rule: **any addition or
modification** means `accepted` is missing shipped content — reconcile.
**Deletions only** usually means `accepted` merely gained files after the freeze
— but a shipped file *deletion* looks identical in this diff, so **when in doubt,
reconcile**: the merge is non-destructive either way.

### The reconcile recipe

The ship prints this, but it is inlined here so this SOP stands alone. It merges
in a **throwaway worktree**, never your primary:

```bash
git -C <path> fetch origin
git -C <path> worktree add --detach /tmp/reconcile-accepted-<repo> origin/accepted
git -C /tmp/reconcile-accepted-<repo> merge origin/main
git -C /tmp/reconcile-accepted-<repo> push origin HEAD:accepted
git -C <path> worktree remove /tmp/reconcile-accepted-<repo>
```

It bases off `origin/accepted`, never the local branch — the primary's LOCAL
`accepted` is routinely **tens of commits stale** (measured at 45), and merging
onto it produces a push that is refused. If `worktree add` complains the path
**already exists**, an earlier recovery was abandoned; the **BAIL OUT** command
below (`worktree remove --force`) clears it, then re-run from the top.

**The merge step can stop on a conflict, and that is expected** — see the gem note
below. When it does, it prints the conflicted files and **your primary is
untouched, still on `main`, still clean**. Pick one:

```bash
# FINISH IT — resolve the files in the scratch worktree, then:
git -C /tmp/reconcile-accepted-<repo> add -A && git -C /tmp/reconcile-accepted-<repo> commit --no-edit
git -C /tmp/reconcile-accepted-<repo> push origin HEAD:accepted
git -C <path> worktree remove /tmp/reconcile-accepted-<repo>

# BAIL OUT — discard everything, leave no residue:
git -C <path> worktree remove --force /tmp/reconcile-accepted-<repo>
```

Expect **DIVERGED to be the common outcome on any release carrying a gem**, and
expect that merge to be the one that conflicts. Since #588,
`bump_consumer_locks_for_qa` commits consumer lockfile bumps onto `release` during
prepare, so the frozen tree legitimately differs from `accepted`'s — a true
verdict, not a regression — and the file it touches, `Gemfile.lock`, is the one
most likely to have been touched on `accepted` too. The routine path and the
conflict path are the same path, which is exactly why the merge is kept off your
primary: on a **gem repo**, modified tracked files in the primary **abort the next
ship**.

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

**The seal retries once through the boot window — expect a possible ~30s
pause.** The seal runs seconds after the deploy, so its smoke can land inside
the dyno boot/restart window and fail against a perfectly healthy prod
(rel-20260720-c06235 red-sealed on `GET /tasks`; the re-run sealed 5/5 green).
On a first failure the ship prints `🔁 first smoke attempt failed — waiting 30s
for the dyno boot window, retrying once`, waits **30s**, and re-runs the suite
**once**. That pause is expected behavior, not a hung ship — do not interrupt
it. A first-attempt pass never waits. When reading the result:

- **Green with "retried once after 30s boot-window wait"** in the summary — it
  passed on attempt two. Prod is healthy; the first run caught the boot window.
- **Red** — the failure **persisted** through the retry. This is a confirmed
  failure rather than a timing blip, so weigh it accordingly. The seal is still
  non-blocking and still never auto-rolls-back: the rollback commands print,
  and you decide.

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

## Close out the cycle — run `archive-shipped`

**A completed ship ends by running [`archive-shipped`](archive-shipped.md).** The
release that just went to production is the cycle that is now finished, and this
is the beat that closes it: shipped tasks archived, completed releases closed,
finished desks reclaimed, regenerable disk swept, frozen docs retired.

Running it here is what makes the cleaning **natural** rather than remembered.
Left to a separate invocation, the archive is the step that gets skipped, and the
cost compounds quietly — a board carrying shipped rows nobody closed, and a
machine carrying desks for work that went out days ago.

```bash
bin/release archive --dry-run     # preview — read it
bin/release archive --yes         # apply
```

Three conditions on this step, and none of them is optional:

- **Only after the ship is green.** A ship that ABORTED has nothing to archive —
  the release is still `assembled`. Fix the blocker, re-run the ship, then
  archive. Never archive past a failed ship to "tidy up".
- **It is a separate verdict, and it can refuse.** `bin/archive-docs` stops the
  beat when the ledger has lost rows, and `bin/release archive` honours that exit
  code. **A refusal here does NOT unship anything** — production is already live
  and correct. Recover the row per [`archive-shipped`](archive-shipped.md) and
  re-run the archive; do not touch the release.
- **Report both halves separately.** The ship's result and the archive's result
  are different facts about different state. A reader must be able to see a green
  ship next to an archive that refused.

**Nothing to archive is a clean answer.** The archive is idempotent — if the prior
cycle was already closed out, it reports "nothing to archive" and stops.

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
- **the archive result, separately** — tasks archived and releases closed, or
  "nothing to archive", or the refusal and what it named

On a clean no-op, report "nothing to ship." A no-op ship archives nothing either;
run [`archive-shipped`](archive-shipped.md) directly when a prior cycle still
needs closing out.

## Related

- [`../../avi/sops/qa-release.md`](../../avi/sops/qa-release.md) - Avi's assembler
  act that produced the QA-green release this ships.
- [`archive-shipped.md`](archive-shipped.md) - Steffon's post-ship closeout act.
- [`../../../modules/gates/g4-ship.md`](../../../modules/gates/g4-ship.md) -
  the G4 Ship gate this act produces.

## Background — not needed to execute

- [`../../../system/devops-cycle-design.md`](../../../system/devops-cycle-design.md)
  §1.4 - release atom model and production gate (architecture).
