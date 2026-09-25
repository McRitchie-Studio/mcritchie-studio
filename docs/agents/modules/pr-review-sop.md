# PR Review SOP (modular) — the `review-one` primitive

This is the **reusable, self-contained PR-review procedure**: the review half of
the Deploy workflow (`submitted → reviewed`). The release design
([`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §1.2 /
§1.4), the [heartbeats launcher map](heartbeats.md), and Carl's
[`pr-review`](../agents/carl/sops/pr-review.md) /
[`pr-review-slow`](../agents/carl/sops/pr-review-slow.md) SOPs include this
module **by reference**. Edit the review contract here and it flows everywhere.

> **This module IS the `review-one <task>` atom.** One run = **one PR / one
> task**: the review session spins **one Carl per PR** (the standing primary + owner) →
> Carl summons **one domain LIGHT** at his discretion → on a merge-ready verdict
> Carl **merges the feat PR into `accepted`**, drives the task to **`reviewed`,
> and STOPS**, or **any** reviewer blocks. Review never touches `release`/`main`
> and never deploys: Avi's `qa-release` sweep promotes `accepted → release` and
> flips members `assembled` on QA-green. **`pr-review`** loops this body across the
> `submitted` queue in **waves of ≤5**; **`pr-review-slow`** runs it one PR at a time.

**There is no Avi supervisor.** Carl reviews deeply, owns the gates, summons the
light, drives the verdict, and merges. Each reviewer reviews **as their own
soul**, attributed in the Agent column of `/xan/heartbeat`. Stage ownership stays
as `devops-cycle-design.md` §1.2 defines it; this is the how-to.
History and rationale cut from this page live in
[`../archive/pr-review-sop-2026-09-25.md`](../archive/pr-review-sop-2026-09-25.md).

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](token-session.md)).

## When to invoke

Run this whenever a `submitted` task's PR needs review: as the `review-one` atom
inside a `full-cycle` / `deploy-with-task` composition, as the body of a Carl
Heartbeat `pr-review` / `pr-review-slow` sweep, or as a one-off review a conductor
kicks off by hand. A queue runs in **waves of ≤5 concurrent agents** (the board
DB's connection budget; a Carl and his light count as two).

You are the **SESSION orchestrator**, not a feature agent. Do not create a task,
take a worktree, or write feature code.

## The reviewer pool — Carl is the standing primary; the light is the domain pick

| Change surface | Light reviewer soul | `subagent_type` |
|---|---|---|
| Backend — Rails, models, jobs, services | **Carl** is primary; light rarely needed | `carl` |
| UI — ERB, Tailwind, Alpine, theme | **Shannon** | `shannon` |
| On-chain / Solana — turf-vault, `Solana::*`, wallets | **Jasper** | `jasper` |
| Infra / deploy — Heroku, CI, env, buildpacks | **Steffon** | `steffon` |
| Docs / operating-model — agent docs, runbooks, README | **Xan** | `xan` |

Xan is also the pool's Documentation seat. Each review names **one PRIMARY** (Carl) and **one LIGHT**.

## Step 1 — the session spins one Carl; Carl's gate-zero

The session claims a green-CI PR (`bin/task claim-next-review`) and **spins one
Carl** (Agent tool, `subagent_type: carl`) as the **review OWNER**. Carl:

1. Re-checks the PR's **live GitHub CI** with his gate-zero, `bin/dor-check <task>
   --gate-role review`, which is **strict**:
   - **red** → `bin/task block <task> --kind rework --agent carl` naming the failing checks;
   - **conflicted** (`gh pr view <pr> --json mergeStateStatus` reports `DIRTY`) →
     `bin/task block <task> --kind rework --agent carl` with "merge the PR's base in
     and resolve" (`outcome=ci-conflicted`);
   - **pending** → defer to a later pass; **green** → continue.

   Both bounces are **MECHANICAL**. If the two-bounce breaker (Step 3) refuses one
   on an already-bounced task, re-run it with `--breaker-ack "red CI, mechanical"`
   (or `"merge conflict, mechanical"`); the reason is recorded on the row.
2. Confirms **product-acceptance**: does the open PR (base `accepted`) meet the
   task's acceptance criteria?
3. Determines the **domain LIGHT** by change surface, previewing with
   **`bin/reviewer-select <task> --no-record`**. A preview must carry
   `--no-record`: a bare run RECORDS, and recording takes the review claim (below).
   It scores the pool by domain fit with a logged, seeded-per-task tiebreak and
   **excludes** the QA owner, **every AUTHOR**, and any **busy souls** (`--busy
   a,b,c` and/or `--busy-auto`). The pool is never starved below a pair.

   **Every author, not just the last one to claim.** The exclusion reads
   `devops.builders` (stamped on every build claim AND on the submit), unioned with
   `built_by` and every `→ building` event actor **that is a build claim**. A soul
   who picked the work up mid-flight names itself on the submit: `bin/task move
   <task> submitted --actor <soul>`. The set also unions the souls DERIVED from
   the PR itself (commit author `<soul>@mcritchie.studio`, a soul `Co-Authored-By`
   trailer, the PR author), so a claim that named no soul still leaves its commits
   on record.

   **A FIX-FORWARD MAKES YOU AN AUTHOR.** A zap puts your commit in the merged
   diff but makes no build claim. `devops.fix_forward` carries that fact:
   `bin/pr-review` records it whenever the PR head advances under a review. A zap
   OUTSIDE a supervised review is recorded by hand with `bin/task fix-forward
   <task> --agent <soul>`.

   **It REFUSES (exit 2) in three states**, because an empty exclusion list is not
   the same answer as "nobody to exclude":

   | Refusal | What it means |
   |---------|---------------|
   | AN AUTHOR NAMED NOBODY | a `--builder` entry matches no roster soul, including a PARTIAL typo (`--builder steffon,alexx`) |
   | authors unknown | no *soul* is named: `built_by` blank or off-roster, no soul on a `→ building` **build claim**, and none derived from the PR's commits |
   | an author would be SEATED | the pool was too small to drop them all, so one was kept eligible |

   Say which it is: `--builder <soul>[,<soul>]` names the authors, `--builder none`
   asserts that no soul built it. Stamp it durably with `bin/task move <task>
   building --actor <soul>` (it works on a task already at `building`). Every slug
   is checked against the roster (`Task.soul?`), so a typo names nobody and
   refuses, and a typo on the RECORD (`built_by: shanon`) is quoted back.

   **YOUR OWN BOUNCE NO LONGER CAUSES ONE.** `bin/task block <slug> --kind rework`
   lands the task on building, and every reader that took that for a build claim
   used to record the reviewer. All of them now distinguish a review write from a
   build write, so a bounce leaves the author set as it found it. If a bounced
   task still refuses, the missing author is a REAL one.

   **The SEATED refusal has no widening flag.** The light pool is already at its
   maximum; `--qa-owner` can only hold or shrink it. The only lever is `--builder`,
   stating a smaller true author set.

**Recording is the DEFAULT — and recording ACQUIRES the review claim first.**
`bin/reviewer-select <task>` writes Carl + the light onto the task as the live
**review intent**, so `/deployments` and the task timeline show them reviewing the
moment review kicks off. Pass **`--no-record`** / `--dry` for an advisory preview
that claims nothing and writes nothing. (`--record` is a back-compat no-op.)

**So preview with `--no-record`, never with a bare run.** A bare "preview" takes
the task's review claim: a **~3h25m lease** (`ClaimLease::REVIEW_TTL_SECONDS =
12275`) with **no renewer behind it**. A live claim row drops the task out of
`Task.reviewable` (`app/models/task.rb`) and therefore out of `bin/task
claim-next-review` for the whole TTL. From the session that popped the task the
claim is already yours (`same_instance`); it is the bare run from a FRESH session
that strands the task.

**Exit 10 is a SKIP, and it has TWO arms with opposite remedies.** Both print to
stderr, select nothing and record nothing. `bin/pr-review` reads exit 10 as a skip
and NAMES the arm (`ReviewerSelectSkip`, `bin/lib/reviewer_select_skip.rb`); a
refusal matching neither phrase is reported as unclassified, naming BOTH arms.
On any exit 10, `bin/reviewer-select`'s stderr is the authority:

| Arm | What it means | The move |
|-----|---------------|----------|
| **held** (`refuse_held!`) | a DIFFERENT live session already holds this task's review claim; the message NAMES the holder | Review another task — `bin/task claim-next-review`. Read a suspect lease with `bin/task review-claim status <task>`; ask the holder to `bin/task review-claim release <task>` rather than taking it from them |
| **self-review** (`refuse_self_review!`) | the board refused the claim because the primary is in this task's AUTHOR SET. It names NO holder | Reconcile the author set, do not retry: `bin/task show <task> --verbose`, then `bin/task move <task> building --actor <the-real-builder>` |

Two more states are **degraded, not refusals**: no agent session (a plain shell or
CI) and an unreadable board. Both print the pick as ADVISORY and record nothing.

**The manual fallback is the CLAIM, not a bare intent.** Take it with
**`bin/task review-claim acquire <task>`**: one atomic write gets you the crew seat
**and** the reservation behind it. Do **not** hand-run `bin/task intent <task> --to
reviewed`: it POSTs the intent and never touches the claim table. (The DEPLOY
lane's `bin/task intent --to assembled` / `--to shipped` fallback stands: no claim
gates those stages.)

Carl then **summons his LIGHT** (Step 2), his own child, nested under him.

## Step 2 — Carl reviews deep; the LIGHT reads AS its soul

Carl runs the deep review
([`../agents/carl/sops/pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md))
and **summons one LIGHT** (Agent tool, the light's domain `subagent_type`) for the
focused second read
([`../agents/carl/sops/pr-review-light.md`](../agents/carl/sops/pr-review-light.md)).
Carl summons **at most one** light; he may skip it on a trivial change and note
that he did. The Agent-tool `description` **is** the action label: **`light
review: <soul>`** (`bin/pr-review` prints the same label).

**The split is role, not just depth.** **Carl, the PRIMARY, is the review OWNER**:
he runs the gates (`bin/dor-check <task> --gate-role review` / cert / CI /
acceptance) and **drives the verdict**. The **LIGHT reports up to Carl**: it does
**not** run the gates and does **not** drive the verdict. **Any reviewer may RAISE
a blocking finding; only the reviewer the review claim records as its holder may
SPEND the task's bounce** (Step 3).

**The review is the task's G2 Review gate** ([`gates/g2-review.md`](gates/g2-review.md)):
two lanes, `g2a_primary` + `g2b_light`, each closed from its own reviewer's scout
report (`merge-ready` = passed). Carl's gate-zero runs with `--gate-role review`,
so it opens+closes its own `dor_review` gate and never touches the builder's G1
Cert or a G2 lane. `bin/pr-review` posts these markers; on a hand-run review Carl
posts them with `bin/gate` (commands in the gate doc).

**Each reviewer narrates as their own soul:**

```bash
bin/agent-activity start --category Verify --agent <soul> --task <task-slug> --reason "review: <task-slug>"
# … diff, checks, tests, DoR …
bin/agent-activity end --outcome "<verdict>: <one-line reason>"
```

Each reviewer **responds with concise notes** on:

- **diff vs. acceptance** — the change does what the acceptance criteria say.
- **checks / tests** — the shape's DoR **base** tiers are green in `checks_run`;
  `bin/dor-check <task> --gate-role review` passes.
- **code standards + code smell + scalability** — Carl goes deep (Opus on
  `migration` / `payment` / `solana` / `auth`); the LIGHT gives a focused read.
- **docs** — behavior/env/ports/auth/deploy changes carry doc updates.

### The prior-art obligation — before you say a change EXPOSES anything

**Whoever asserts that a diff introduces, exposes, or widens a risk owes the
prior-art check first.** Answer three things before "introduces", "first
consumer", "now user-visible", or "makes it reachable" go into a finding:

1. **Did this surface already exist here?** Read what the diff REPLACED, deleted
   files included — `git show origin/accepted:<path>` and `git diff --diff-filter=D --name-only origin/accepted...HEAD`.
2. **Under what controls?** Same route, same CSP, same auth, same data — or different?
3. **What actually CHANGED?** State the delta in one line. "Net exposure change:
   zero" is a complete answer.

If you did not look, **say so in those words** — `prior art: not investigated`.
A finding that omits prior art reads as *"none"*. Record the answer when you file:

```bash
bin/triage file --title "…" --body "…" --repo <app> --source <soul> \
  --prior-art none                       # I looked; the surface is new here
bin/triage file --title "…" --prior-art "TM's deleted preview view carried the identical iframe since 2025-11"
# omit --prior-art entirely -> recorded as "unknown" (nobody looked), and it says so
```

Reviewers may also broadcast in-app progress with
`POST /api/v1/tasks/:slug/review_events` (primary = `primary` swimlane, light =
light swimlane) — see [`parallel-agent-devops.md`](parallel-agent-devops.md#picking-the-domain-light-binreviewer-select).

## Step 3 — The claim holder spends the bounce

**A block is spent only on a REACHABLE regression** — a correctness, security,
or data-loss defect someone can actually hit, or an acceptance criterion the diff
does not meet — named with its trigger. A zap-scale finding is **fixed forward**
on the PR branch ([`zap-protocol.md`](zap-protocol.md) reviewer seam, verdict stays
merge-ready); scope/style/hardening ideas ride as `bin/task note --comment`;
metadata gaps the reviewer repairs with `bin/task update`. If a block is earned,
**the review claim's holder** sends it back once and the session moves on:

```bash
bin/task block <task> --kind rework --summary "<4-6 word headline>" --feedback "<what is wrong + why>" --agent carl
```

**Any reviewer may RAISE a blocking finding; only the claim's holder may SPEND
the bounce.** `--kind dependency` and `--kind environment` spend no bounce. So a
**LIGHT reports** a defect up as a scout report (`--outcome request-changes`) and
the primary decides.
Either reviewer records a finding **without** spending the bounce:

```bash
bin/task note <task> --comment "<your finding>"
```

**Two-bounce circuit breaker:** a task that already carries a prior send-back is
never re-blocked to the builder. Read it with `bin/task bounces <task>`: **exit 0
= CLEAR is the only exit that authorizes a re-block**, 10 = TRIPPED, and any other
non-zero is a FAILED read or an unknown slug. `bin/task block --kind rework` runs
the same check and refuses the second bounce on its own. It counts `qa_feedback`
rows, never the live block columns. On TRIPPED, escalate instead (`bin/task block
<task> --kind dependency --summary "Escalated: <disagreement>" --feedback "<both
positions>" --agent carl`) and flag it **⚠ Escalated** in the handoff. A
MECHANICAL bounce (red CI, merge conflict) proceeds on `--breaker-ack "<reason>"`.

`--summary` is the task header's headline; `--feedback` is the detail. Surface each block in the run handoff as a **❌ Block
Resolved — <slug>: <reason>** line; omit the section on a clean run.

## Step 4 — Verdict

**Carl collects the light's read and drives the verdict.**

- **Merge-ready** (no reviewer blocked) → **Carl merges the feat PR into
  `accepted`** — revalidate the head, `gh pr merge --merge --match-head-commit`,
  then `bin/task move <task> reviewed --actor carl` (merge → move; `reviewed` iff
  the code is on `accepted`; no `merged` stamp, the board derives it) — **and
  stops there.** Carl does NOT run `bin/release merge` and never touches
  `release`/`main`. Avi's **`qa-release`** (`bin/release prepare`) promotes the
  **ONE `accepted → release` batch PR per repo** and flips members `assembled` on
  QA-green. **Bias to action: a clean merge-ready verdict = go.**
  For a registered **gem**, the merge is followed by a read-only
  **upstream-changelog audit** of that gem's `accepted` (`UpstreamMisfile.audit`).
  It prints a finding and never fails the review.
- **Any block** → the task is at `blocked` (Step 3) until the builder resubmits.
- **Low confidence** (humility valve) → a reviewer marks `conductor-review` and
  routes to a human Carl / Avi / Steffon session instead of merging.

## At a glance

| # | Actor | Agent (`subagent_type`) | Does | Records |
|---|---|---|---|---|
| 1 | **Session Pokémon** (orchestrator — never reviews) | base mascot | `bin/task claim-next-review` → spins one Carl per PR | claim lease on the task |
| 2 | **Carl** (PRIMARY — review OWNER) | `carl` | product-acceptance + gate-zero (`--gate-role review`); deep review; **owns the gates** + **drives the verdict**; **summons one LIGHT** (`light review: <soul>`); on merge-ready **merges the feat PR into `accepted`** (runs `pr-review-primary.md`) | review intent (pair); opens the `dor_review` gate-zero + the G2a lane; `submitted → reviewed` + `merged: accepted` |
| 2 | **LIGHT** | domain soul | focused second read; **reports up to Carl**; no gates, no verdict-drive (runs `pr-review-light.md`); Carl's **child** | `Verify --agent <soul>` activity + notes; closes the G2b lane |
| 3 | **Carl** (the review claim's holder) | `carl` | block on a defect — any reviewer may RAISE one, only the claim's holder SPENDS the bounce | `bin/task block --kind rework --feedback --agent carl` (a light instead: `bin/task note --comment`) |

## Where this plugs in

- [`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §1.2 / §1.4 — canonical stage ownership.
- [`../agents/carl/sops/pr-review.md`](../agents/carl/sops/pr-review.md) and
  [`../agents/carl/sops/pr-review-slow.md`](../agents/carl/sops/pr-review-slow.md)
  — the Carl-owned SOPs that run this cascade, spinning one Carl per PR who runs
  [`pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md) and summons
  [`pr-review-light.md`](../agents/carl/sops/pr-review-light.md).
- [`parallel-agent-devops.md`](parallel-agent-devops.md) — `bin/reviewer-select` mechanics and the review-events API.
- [`review-comment-taxonomy.md`](review-comment-taxonomy.md) — which activity type a reviewer's note uses.
- [`heartbeats.md`](heartbeats.md) — the launcher map that invokes this cascade.
