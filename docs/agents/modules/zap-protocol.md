# Zap Protocol — fix small defects in place

You found a small defect mid-cycle: a typo in the UI, a wrong doc path, an
off-by-one in a label, a missing nil-guard one line wide. **Zap it.** Fix it in
place, on the branch you already have, with no new board task. This module is
the standing license to do that — and the bounds that keep zaps from becoming
their own devops mess.

The problem this solves: every small defect used to spawn a fresh task, which
spawned a worktree, a branch, a PR, a review, and a release slot — more process
than the fix. The zap protocol replaces that with **one commit, one check, one
note** on a record that already exists.

A **zap** is one commit, prefixed `zap:`, that fixes ONE small defect found
mid-cycle, carries its own check, and is recorded with `bin/task note` on the
nearest existing record. Never a new board task; never a chain.

## Eligibility — every bound must hold

A fix qualifies as a zap only when **all** of these are true:

- **Size** — at most **25 changed lines** across at most **2 files**.
- **No structure** — no migrations, no new dependencies, no new routes or
  endpoints, no secrets or env-var changes.
- **In-cycle repos only** — only repos the active task or release already
  touches. A defect in an untouched repo is a task, not a zap.
- **One defect, one commit** — a zap fixes exactly one issue in exactly one
  commit. Two defects are two zaps (each within bounds) or one task.

If **any** bound fails — or you are unsure — it is not a zap. Create a normal
task and run the full cycle:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task create --title "<3-5 words>" --kind bug --shape <shape> \
  --repo <app> --accept "<criterion>" --no-claim
                 # --no-claim: filing is not building — leave your session's
                 # active-feature marker on the live lane
```

Judgment calls resolve **toward the task**, never toward a bigger zap.

## The test rule

Every zap carries a check at the **lowest tier that exercises the fix**, run
before you push:

- A behavior fix (even one line) gets a test at the lowest tier that reproduces
  it — usually `[unit]` — added or adjusted inside the same zap commit and
  inside the same size bounds.
- A pure typo or doc zap may skip the test, but the recording note must say so
  explicitly: `no-test: copy-only, no behavior change`.

A zap whose check **fails** is dead on arrival: revert it and escalate (see the
guard below). Never push a zap with a red check to "fix forward."

## The three seams

Where you commit depends on which seat you hold when you find the defect.

| Seam | You are | Zap lands on | Recorded on (`bin/task note`) |
|---|---|---|---|
| **Builder** | Feature agent, mid-build | Your own `feat/<slug>` branch | Your own task |
| **Reviewer** | Primary/light reviewer, mid-review | The PR branch under review (lease-push a `zap:`), or NAME it in the verdict | The task under review, via the verdict finding |
| **Conductor** | Sweep/release conductor | `accepted` only | The nearest member task of the open release |

**Every seam that applies a zap prepares it on a throwaway desk** — a
detached worktree, never a checkout that holds other work. The payoff is the
abort path: discarding the throwaway (`git worktree remove --force <path>`)
removes the working copy, the index, and any zap-created files together — and
cannot touch a desk where unrelated work lives. The same rule covers a
reviewer's mutation pass, for the same reason in reverse: a mutation is a write,
and a write into an occupied desk corrupts whatever else is reading it (see
[The Desk Writer Convention](worktrees.md#the-desk-writer-convention)).

**Cut it under `.worktrees/`, and carry `.env.test.local` across.** Both halves
are load-bearing the moment your zap runs a test tier:

```bash
REPO="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"   # the PRIMARY checkout, from anywhere
ZAP="$REPO/.worktrees/zap-<slug>"
git worktree add "$ZAP" --detach <base>
cp <desk>/.env.test.local "$ZAP"/     # or: bin/agent-worktree new <app> zap-<slug>
```

`.env.test.local` is **untracked**, so no `git worktree add` carries it. Without
it `TEST_DATABASE_URL` renders empty, `config/database.yml` falls back to
`database: <app>_test`, and the throwaway's test tier runs against the **shared**
test database used by the primary checkout, CI, and every concurrent suite —
polluting them and being polluted by them. Verified 2026-08-31: a detached
worktree off `origin/accepted` resolves to `mcritchie_studio_test`.

Cutting it under `.worktrees/` is what lets `bin/lib/desk_guard.rb` catch that
for you. Its `desk?` predicate returns true **only** for a path whose parent
directory is `.worktrees`, and where `../zap-<slug>` lands depends on the seat
you hold. From the primary checkout — the reviewer and conductor seats — it
resolves *outside* `.worktrees/`, so it is **never refused** and fails silently.
From a desk — the builder seat — it resolves to a sibling *inside* `.worktrees/`,
where the guard does fire. Cutting under `.worktrees/` deliberately stops the
answer depending on where you happened to be standing: the tree is refused by
name, with the missing file called out.

### Builder — on your own feat branch

You are building a task and notice a small defect in code your cycle already
touches. Prepare the zap on a throwaway desk off your feat head — your build
desk may hold uncommitted work a cleanup must never touch — and land it as
its own commit:

```bash
ZAP="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")/.worktrees/zap-<slug>"
git worktree add "$ZAP" --detach HEAD          # throwaway desk off your feat head
cp .env.test.local "$ZAP"/                     # REQUIRED before any test tier
cd "$ZAP"
# …fix, then:
git add -p
git commit -m "zap: <what was broken, one line>"
git push origin HEAD:refs/heads/feat/<slug>    # fast-forward; rejects loudly if stale
cd - && git worktree remove --force "$ZAP"
git pull --ff-only origin feat/<slug>          # bring your desk level
```

Record it the way every seam records — a `bin/task note` on your own task
(the board CLI lives in the hub; run task writes from there whichever repo
the zap touched):

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task note <your-task> \
  --comment "zap: <defect> — commit <sha>, <check run, or no-test: rationale>"
```

A `[zap]` line in `checks_run` is optional color, never the record — if you
add one, remember **`--checks` REPLACES the whole list** (pass every line you
want kept). The zap rides your PR through normal review; the reviewer sees
the `zap:` commit and the note and judges it with the rest of the diff.

### Reviewer — apply a bounded zap, or name it

You are reviewing a PR and find a small defect — in the diff, or adjacent
code the diff exposed. You have two moves.

**Apply it** when the fix is in zap bounds. Prepare it on a throwaway desk off
the PR head, run its test tier, and **lease-push** the `zap:` commit to the PR
branch:

```bash
ZAP="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")/.worktrees/zap-<slug>"
git worktree add "$ZAP" --detach FETCH_HEAD           # off the PR head you fetched
cp <desk>/.env.test.local "$ZAP"/                     # REQUIRED before any test tier
cd "$ZAP"
BASE=$(git rev-parse HEAD)                            # the head you zap FROM — pin the lease to it
# ...one bounded fix...
git commit -m "zap: <what was broken, one line>"
git push --force-with-lease=refs/heads/feat/<slug>:$BASE origin HEAD:refs/heads/feat/<slug>
cd - && git worktree remove --force "$ZAP"
```

An **explicit** lease-push (`--force-with-lease=<ref>:<sha>`), never a **bare**
`--force-with-lease` and never a plain force-push: the pinned form expects the
remote branch to still be at the exact `$BASE` you zapped from, so if a sibling
zap or a builder push advanced it first, your push is REJECTED rather than
overwriting their commit. A bare `--force-with-lease` trusts your local
remote-tracking ref, which a background fetch can quietly advance — that defeats
the guard and clobbers the sibling, so the explicit `=<ref>:<sha>` form is the
safe one. If your push rejects, a sibling already landed: do NOT retry or
override — name the fix in your verdict instead. Then leave your verdict
**merge-ready** and let the zap's own CI vouch for it — the `bin/pr-review`
supervisor **captured the head BEFORE it launched your review and REVALIDATES it
before merging** (the merge is pinned with `--match-head-commit`): an advanced
head merges only if its post-zap CI is green, and holds for re-review otherwise
(it never merges a head the reviewers didn't see on a non-green CI). Record the
zap on the task the ordinary way (§ Recording).

**Name it instead** when it is out of bounds, or you'd rather not apply it:
state the file and line, the one-line fix, and the bounds check (e.g. `within
zap bounds: 3 lines, 1 file, no structure`) in your verdict, and it travels
without you —

- On a merge-ready verdict, a named defect can land afterward as a **conductor
  zap on `accepted`** (the seam below), riding the current RC only if it lands
  before that repo's `accepted → release` promote.
- When the defect is the reason the PR cannot merge, it is not a zap from the
  review seat at all: the supervisor routes it as rework feedback (`bin/task
  block <task> --kind rework --feedback "…"`) and the builder fixes it on the
  feat branch — where it may well be a builder zap.

### After a reviewer zap — what re-checks itself, and what does not

Pushing a zap moves the PR head. Some of the machinery around the review notices
and some of it does not, and the difference used to be invisible. Measured on
2026-09-02 across three reviewers in one afternoon; two got the right answer only
because they happened to re-verify by hand.

| Fact | Re-checked after your push? |
|---|---|
| GitHub CI verdict | **Yes** — checks re-run on the new head. |
| The tree `bin/dor-check --gate-role review` grades | **Now guarded.** It re-roots to the *builder's desk*, which sits wherever the builder left it. It refuses when that tree is not the PR head. |
| The full-suite cert fingerprint | **Only sometimes** — see below. |
| The e2e declared-vs-executed set | **No** — it ran once, against the base as it was then. |
| The task's stage | **No mechanism found.** See the open question below. |

**The gate now refuses a stale tree rather than grading one.** `--gate-role
review` re-roots to the builder's desk, and on turf #519 that desk sat at
`262059b` while the merged commit was `9137d57`. `bin/dor-check` now compares the
commit it is about to grade against the PR head and refuses on a mismatch,
naming both SHAs. The remedy is one command:

```bash
git fetch origin <branch>     # then re-run dor-check
```

**Do not rely on the cert fingerprint to catch your zap.** It often does — the
cert is bound to a git *tree* hash, so a zap changes the tree and the cert reads
STALE (observed on solana-studio #29, where the reviewer had to re-certify). But
it hashes `origin/<branch>` **in the builder's desk**, and `bin/dor-check` never
runs `git fetch`. Push your zap from that desk and the ref moves as a side effect,
so the cert goes stale as expected; push it from anywhere else and the desk's ref
stays pre-zap, the hash still matches the builder's cert, and the lane reads
FRESH. Same act, opposite outcome, decided by which checkout you were standing
in. If the zap was yours, re-certify it: `bin/full-suite-check <task>`.

**A base that moves mid-review is reported, not refused.** `accepted` moves
constantly and blocking every review after any merge would wedge the lane, so
`dor-check` re-derives base movement from local refs and prints it as a
suggestion. Take it seriously when the e2e counts matter: turf #517 merged **97
seconds after** #519's declared-set check finished, and it touched both
`e2e/auth_modal.spec.js` and `config/e2e_lane.yml` — the spec set *and* the
contract that counts it. That review came out right by luck. GitHub's own
`BEHIND` signal is not a substitute: it only appears where branch protection
demands an up-to-date branch, and `UNKNOWN` is passed over in silence.

**OPEN QUESTION — what demotes a task out of `submitted`.** It was believed that
a reviewer zap demotes a task out of the review queue, citing turf #513. **That
was falsified:** on #518 a reviewer pushed a zap and the task stayed `submitted`
with the breaker clear. The zap and the demotion merely co-occurred on #513, and
what actually moved it overnight is **still unidentified**. No zap-demotion
mechanism exists in the code — every stage writer found is an explicit call
(`Task#block!` via `bin/task block`, `bin/pr-review`, the block endpoints, the
web Block button, `Release::Conductor.eject!`) or a bare stage write through
`PATCH /api/v1/tasks/:slug`, which validates no transition. Nothing is keyed on a
branch push. If you see a task move after a zap, the `TaskEvent` row that
`after_update :record_transition_event` writes is where the mover is named —
capture it, because nobody has yet. Do not repeat the zap-demotion story as
mechanism.

### Conductor — on `accepted` only

You are sweeping or assembling a release and find a small defect in code
already merged. Land the zap directly on `accepted` — no new task, no new PR,
no extra release slot. **Which release it rides depends entirely on timing**
(the rule below). Prepare it on a throwaway desk, never on the primary
checkout (the conductor's integration floor holds state a cleanup must never
touch):

```bash
git fetch origin accepted
ZAP="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")/.worktrees/zap-<slug>"
git worktree add "$ZAP" --detach origin/accepted   # throwaway desk
cd "$ZAP"
# Running a test tier here? This throwaway has NO desk to copy .env.test.local
# from, and under .worktrees/ desk_guard refuses that cert lane by name — which
# is the right failure, but it leaves you holding a refusal. Provision a real
# desk instead:  bin/agent-worktree new <app> zap-<slug>
# …fix, then:
git add -p
git commit -m "zap: <what was broken, one line>"
git push origin HEAD:refs/heads/accepted       # fast-forward; rejects loudly if stale
cd - && git worktree remove --force "$ZAP"
```

Two hard edges:

- **Never `release`, never `main`.** Complications resolve on `accepted` —
  the only rung a conductor writes. `release` moves by the sweep's promote
  alone; `main` moves by `bin/release ship` alone.
- **The promote is the cutoff — a zap reaches the CURRENT candidate only if
  it lands before that repo's `accepted → release` promote.** Land it before
  the sweep and it rides this RC through G3 QA and G4 unchanged. Land it
  after, and it sits on `accepted` and rides the **NEXT** release — it does
  not reach the in-flight one, and must never be described as fixing it.

**Why re-running the sweep does not back-fill an in-flight RC.** The promote
is candidate-driven: `bin/release prepare` promotes only repos whose member
tasks are still stamped `merged: "accepted"` (`bin/release.rb`, the
`promote_repos` selection). Once a sweep records membership it re-stamps
those members `merged: "release"`, so a later re-run finds nothing to promote
for that repo and the zap on `accepted` is skipped — the RC keeps its old
SHA. The sweep self-heals INTERRUPTED promotes; it does not re-promote
`accepted` drift into a candidate it already built.

**If the defect must reach an already-promoted RC, it is not a zap.** Two
implemented paths, both normal cycle work:

- **Let the RC ride and fix forward** — file a normal task; the fix lands in
  the next release. Correct whenever the defect is not release-blocking.
- **Eject and re-prepare** — when the defect makes the RC unshippable,
  `bin/release eject <member-task>` detaches the offending member (blocking
  it for rework) and prints the git unwind; re-running `bin/release prepare`
  then rebuilds the RC without it. Ejecting removes a member; it does not
  inject a fix.

Record it on the nearest member task of the open release — the task whose
change surfaced or contains the defect; if none fits, the member task closest
to the touched code (task writes run from the hub):

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task note <nearest-member-task> \
  --comment "zap: <defect> — commit <sha> on accepted, <check run, or no-test: rationale>"
```

**Worked example — the protocol's first live use.** Conductor zap `ec81dbb2`
fixed three stale release-first comments in `bin/agent-worktree` directly on
hub `accepted` — one commit, one file, 12 changed lines, inside every bound —
comment-only with an explicit `no-test:` rationale, recorded with `bin/task
note` on `worktree-fresh-start-sop`, the nearest existing record. It landed
**before** the hub's `accepted → release` promote, which is exactly why it
rode that candidate; the same commit made after the promote would have waited
for the next release.

## Recording — one ledger, never a new task

Every zap leaves the same two-part trail, whatever the seam:

1. **The commit message prefix `zap:`** — this is the machine-readable marker.
   `git log --oneline --grep '^zap:'` must find every zap on a branch.
2. **A `bin/task note` on the nearest existing record** — the builder's own
   task, the task under review, or the nearest member task of the open
   release. The note names the defect, the commit SHA, and the check run (or
   the explicit `no-test:` rationale).

**The note is the ledger at every seam, builder included.** A `[zap]` line in
`checks_run`, or a zappable defect named in a review verdict, is color on
top — never a substitute for the note.

The board CLI lives in `mcritchie-studio`: run every `bin/task` write from
the hub (`cd /Users/alex/projects/mcritchie-studio && bin/task …`), whichever
in-cycle repo the zap commit landed in.

That is the whole ledger. Do **not** create a board task for a qualifying zap —
the entire point is that the fix attaches to a record that already exists.

## Escalation guard — one zap per issue, no chains

This is the rule that makes loops impossible. **Each issue gets at most one
zap, ever.** When any of these happens, the zap lane is closed for that issue:

- The fix **grows past any eligibility bound** while you write it.
- The zap's **check fails**, at commit time or later in the pipeline.
- The **same defect resurfaces** after a zap claimed to fix it.
- The candidate fix would **touch a `zap:` commit** — a zap may never fix,
  amend, or revert another zap.

In every case the move is the same — **stop and escalate.** What you clean up
first depends on whether the zap commit was pushed yet. Because every zap is
prepared on a throwaway desk, the abort discards that desk and nothing else —
no cleanup here may ever run on a checkout that holds other work:

**Not pushed yet** (the fix outgrew bounds mid-write, or the push was
rejected) — discard the throwaway desk whole; working copy, index, and
zap-created files go together, and no shared desk is touched:

```bash
git worktree remove --force "$ZAP"
```

**A zap commit landed** (failed check, resurfaced defect, zap-on-zap
candidate) — the bad commit is on a REMOTE branch, so reverting locally is
not enough. Roll it back on the branch it actually landed on: `feat/<slug>`
for a builder zap, `accepted` for a conductor zap. Same throwaway-desk rule,
because the revert is another commit:

```bash
ZAPPED=<feat/your-slug | accepted>       # the branch the zap landed on
git fetch origin "$ZAPPED"
git worktree add ../unzap-<slug> --detach origin/"$ZAPPED"
cd ../unzap-<slug>
git revert --no-edit <zap-sha>
git push origin HEAD:refs/heads/"$ZAPPED"   # fast-forward; rejects if stale
cd - && git worktree remove ../unzap-<slug>
```

Record the rollback on the same record that carries the zap — the ledger
tracks the reversal, not just the attempt:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task note <same-record-as-the-zap> \
  --comment "zap reverted: <defect> — <zap-sha> reverted by <revert-sha> on <branch>; escalated to <new-task-slug>"
```

**Either way, escalate to a normal task** (`--no-claim`: filing is not
building — leave your session's active-feature marker on the live lane):

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task create --title "<3-5 words>" --kind bug --shape <shape> \
  --repo <app> --accept "<criterion>" --no-claim \
  --agent-context "Escalated from zap <sha, or the aborted attempt>: <what it tried, why it was not enough>"
```

A conductor zap reverted **after** its RC promoted is the timing rule again:
the revert rides the next release, and the in-flight RC still carries the bad
commit — eject or ship-and-fix-forward, per the conductor seam above.

No second zap on the same issue. No zap on a zap. No "one more line and it'll
hold." Chain depth is capped at one by rule, so a zap can never recurse into
the process spiral it exists to prevent.

## What a zap is not

- **Not a scope smuggler.** No refactors, no renames, no "while I'm here"
  cleanups, no feature slivers. A zap fixes a defect; it never improves code
  that was not broken.
- **Not a review bypass.** Builder zaps ride the PR through normal review;
  conductor zaps ride the RC through G3 QA and G4's frozen-SHA gate; and a
  reviewer-applied zap is gated by the supervisor's head revalidation — an
  advanced head merges only on a green post-zap CI. The zap skips the *task
  ceremony*, never the *verification*.
- **Not a pressure valve for big fixes.** A bounded fix that keeps almost
  qualifying is the classic loop-starter. When in doubt, task it.

## Go-live note for this doc

This module lives in `docs/agents/modules/` inside `mcritchie-studio`. Changes
to it — like all agent-doc changes — reach the generated projects-root
`AGENTS.md` and adapters only after `bin/install-agent-docs` runs from the
McRitchie Studio primary checkout.
