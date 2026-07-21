# McRitchie Agent Entry

This is the canonical source for the generated projects-root `AGENTS.md`.
McRitchie Studio owns this file so the agent operating model survives a wiped local machine and can be restored from GitHub.

Paths below are written for the generated file at `/Users/alex/projects/AGENTS.md`.

## SOP Invocation Standard

SOPs are first-class registered commands in this workspace. The set is finite,
the names are stable, and every SOP name maps to a repo file. Do not treat an SOP
name as ordinary prose, generic GitHub triage, or a broad workflow request.

McRitchie operating procedures are normal repo docs, not installed skills. When
Mr. McRitchie names an SOP or heartbeat act such as `pr-review`, `qa-release`,
`production-deploy`, `clean-up`, or `full-cycle`, resolve that phrase through the
SOP registry and directory convention here, read the mapped SOP, then execute it.

SOP locations:

- Agent heartbeats live at
  `mcritchie-studio/docs/agents/agents/<agent>/HEARTBEAT.md`.
- Agent-specific SOPs live at
  `mcritchie-studio/docs/agents/agents/<agent>/sops/<sop>.md`.
- Shared primitives live under `mcritchie-studio/docs/agents/modules/`.

Invocation rule:

1. Open the required trajectory activity.
2. Resolve the invocation in the finite registry below, including legacy aliases.
3. Read the mapped `HEARTBEAT.md` or SOP file before queue inspection,
   `--help` probing, GitHub PR discovery, or tool/plugin selection.
4. Execute the procedure in that file. If it points to a shared primitive, read
   that primitive next.

SOP files stand alone. Each SOP is executable start-to-finish from its own
file — every command, gate, and decision rule is inline. An SOP may reference
only: (1) other registered SOPs at composition seams, (2) a registered shared
primitive such as `modules/pr-review-sop.md`, exactly one hop, and (3) an
explicitly marked "Background — not needed to execute" section. Design docs
such as `system/devops-cycle-design.md` are architecture — the why, never a
required execution path. Do not follow a Background reference to run an SOP.

| Invocation | Owner | Read first |
|------------|-------|------------|
| `pr-review` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review.md` |
| `pr-review-slow` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-slow.md` |
| `pr-review-primary` (role SOP) | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-primary.md` |
| `pr-review-light` (role SOP) | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-light.md` |
| `production-deploy` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/production-deploy.md` |
| `deploy-with-task` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/deploy-with-task.md` |
| `Avi Heartbeat` | Avi | `mcritchie-studio/docs/agents/agents/avi/HEARTBEAT.md` |
| `qa-release` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/qa-release.md` |
| `qa-deploy` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/qa-release.md` |
| `archive-shipped` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| `archive-completed` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| `Steffon Heartbeat` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/HEARTBEAT.md` |
| `full-cycle` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/full-cycle.md` |
| `clean-up` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/clean-up.md` |
| `grade-events` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/grade-events.md` |
| `share-insights` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/share-insights.md` |
| `Alex Heartbeat` | Alex | `mcritchie-studio/docs/agents/agents/alex/HEARTBEAT.md` |

For `pr-review`, read Avi's `pr-review.md` and run the bounded review
supervisor described there. It merges approved work onto `accepted` and stops at
`reviewed` (never `release`/`main`, never a deploy); Steffon's `qa-release`
promotes `accepted → release` plus QA.

## First Rules

- Work from `/Users/alex/projects` unless Mr. McRitchie gives a different root.
- Treat `mcritchie-studio` as the documentation and bootstrap anchor.
- Keep repo-specific facts in the owning repo, but keep cross-repo operating rules here.
- In agent docs and handoffs, **Alex** means the Alex agent/orchestrator. The
  owner/operator is **Mr. McRitchie**.
- When editing active docs, fix nearby ambiguous references you notice:
  **Alex** for the agent/orchestrator, **Mr. McRitchie** for the owner/operator.
  Leave historical/archive snapshots alone unless you are already promoting or
  correcting that file.
- Do not print secrets. Use named 1Password references and purpose-built scripts.
- Do not hand Mr. McRitchie terminal chores. Run safe commands yourself; ask Mr.
  McRitchie for approvals, credentials, product judgment, or external access.
- Prefer a concrete local result Mr. McRitchie can inspect: a URL, a diff, a
  passing command, or a short audit.
- For feature work, identify the feature being requested and accumulate
  acceptance criteria until the agent and Mr. McRitchie are in sync on the
  goal. Do not start implementation from a fuzzy feature request unless the
  remaining ambiguity is low-risk and explicitly called out.
- Worktrees are desks; primary checkouts are loading docks. If you will edit
  code or app docs, create or enter an isolated worktree with an allocated port
  before making changes unless Mr. McRitchie explicitly assigns you as the
  deploy owner for that repo.
- A pushed feature branch preserves code. `main` is for shipped integration,
  not backup. Feature agents push their own branch and open a PR into `accepted`;
  review merges it onto `accepted`, and Steffon's `qa-release` sweep promotes
  `accepted → release` for QA.

## House Writing Style — correct Mr. McRitchie's copy

Mr. McRitchie's prompts and drafts often arrive with spelling and grammar
errors. Treat them as normal input, never as intent. The standing rules:

- **Correct as you transcribe.** When his words head anywhere durable — UI
  copy, emails, docs, task records, PR text — fix spelling, punctuation, and
  grammar on the way through. This autonomy is standing: do not ask permission
  for mechanical corrections, and never reproduce a typo into an app or doc.
- **Mechanics only.** Correct the mechanics; keep his meaning, facts, and
  voice. If a garbled phrase leaves the intent genuinely ambiguous, ask, and
  list the readings you considered.
- **The house guide is *The Elements of Style* (Strunk & White)** — Mr.
  McRitchie's favorite book on writing well. Compose and correct by its
  teachings: omit needless words; prefer the active voice; put statements in
  positive form; use definite, specific, concrete language.
- **Guardrails.** Style corrections never rename code identifiers, routes, or
  API fields on their own; frozen archives and audit snapshots stay as
  written; proper nouns and domain jargon stand. App-bound copy still rides
  the DevOps cycle like any other change.

## House Communication Style — reporting to Mr. McRitchie

Mr. McRitchie reads slowly, but wants full specifics once an idea lands. Every
operator-facing message (chat reply, handoff, task note, PR summary) carries
**two layers, in order**:

- **Layer 1 — the idea.** Lead with the outcome, in plain words, as if
  explaining to a smart 13-year-old. One idea per sentence; each point a
  sentence or less; three sentences is the ceiling before switching to a list.
- **Layer 2 — the specifics.** A table or bulleted list with every handle he
  needs to dive in: task URL, slug, file path, branch, PR URL, local URL +
  port, function name, exact command. Never trade this layer away for brevity
  — simple is not vague.
- **Review handoffs lead with a magic link.** Mint a signed-in link that lands
  on the exact page to review (`Studio::Link.create_magic_link(email:,
  return_to:, ttl: 12.hours)` → `http://localhost:<port>/l/<token>`) and put it
  on a `Magic Link:` label above `Local Demo:`. Recipe in the module below.
- **Form factor:** prefer tables and bulleted lists over paragraphs; keep the
  exact top-level labels (`Task:`, `Local Demo:`, `Local Inbox:`).
- **Name work by its task slug.** The slug (`remove-prod-deploy-approval`) is the
  operator's name for the work; a bare PR number (`#610`) is plumbing. PR
  numbers, branches, and SHAs stay in layer 2, beside the slug they belong to.

Full module: `mcritchie-studio/docs/agents/modules/communication-style.md`.

## 📣 Narrate your trajectory — REQUIRED, every session, unprompted

This is how you work here: **as you work you MUST narrate your trajectory into
activities — without being asked.** Narration is the default, not an add-on; a fresh
session with no explicit prompt still narrates from its first real unit of work.
Your raw tool-calls attribute server-side to whichever activity is currently open, so
a session with no activities reads as a wall of raw tool calls instead of "Explore:
find api issue → found the nil-guard". Do not wait to be told — **your FIRST
activity opens BEFORE your first tool call**: an `Explore` (or `Plan`) "orient" activity —
read the task, scan the code you'll touch — even on a small, pinpointed change. Go
straight to `Edit` and your orientation strands in the "Unlabeled" bucket, so the
"understand the task" beat is lost. Open the orient activity first, then keep the trail
going to handoff.

Open an activity at each natural work boundary:

```bash
bin/agent-activity start --category <Explore|Edit|Verify|Version|Workflow|Delegate|Clarify|Remote|Research|Plan> --reason "what am I doing"
```

When one unit of work ends and the next begins, roll the boundary in **one call**
— close the prior activity with its result and open the next together:

```bash
bin/agent-activity next --outcome "what just happened" --category <C> --reason "what's next"
```

Close the final open activity when the work (or the session) is done:

```bash
bin/agent-activity end --outcome "what happened"
```

- `bin/atomic-event` remains a compatibility alias for existing hooks and older docs.
- **Lead with orient** — your opening activity is `Explore`/`Plan` and opens BEFORE
  any tool runs; nothing should land in "Unlabeled" at the top of a session.
- **Keep activities meaningful** — one per unit of work, not one per tool call
  (navigate `cd` **and** the `bin/agent-activity`/`bin/atomic-event` narration
  calls themselves are dropped automatically; opening a new activity auto-closes
  the prior one).
- **Stamp the task on your first activity** — add `--task <slug>` to `start`/`next`
  so the activity is task-attributed immediately, instead of a blank TASK until a
  later `bin/task`/`bind-task` write lands. In a `feat/<slug>` worktree it's
  inferred from the branch, so `--task` is mainly for a primary/conductor
  checkout working a specific task.
- **Always give a result** — every `next`/`end` records what actually happened
  ("Explore: find api issue → found the nil-guard"), not just the intent; an
  activity without a result is a wasted activity.
- **Log the activity's key method when it has one** — add `--key-method "<code>"`
  (+ optional `--key-lang bash|ruby|sql|js`) to `next`/`end` when the completed
  activity had ONE load-bearing call worth copying — the line another agent (or the
  operator) would rerun, e.g. `--key-method "User.find_by(email: ...)" --key-lang
  ruby`. Most activities have none; skip it rather than invent one. It renders on the
  heartbeat rows as a copyable chip with a language badge. (Raw bash actions get
  theirs automatically — the capture hook logs each Bash call's command as its
  `key_method` and its description as its goal `summary`, so keep writing good
  Bash descriptions.)
- Keep `--reason`/`--outcome` short (~4-7 words).
- **It's non-fatal** — narration never blocks your work, and it powers the Alex
  learning heartbeat (`/alex/heartbeat`). There is no reason to skip it.

## DevOps Routing — read before writing ANY code

If your work will produce a code diff — a feature, a bug, or a chore, **even a
"small" one** — you are a Feature agent and you follow the cycle. There is **no
size exemption**: "it's just a small change" is exactly when this gets skipped.

### The fast lane — the DEFAULT path

Two wrappers collapse the cycle's bookends into one command each. Reach for
them first; the long form below is the fallback.

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task begin --title "Three To Five Words" --repo <app> --kind <kind> \
  --shape <shape> --risk <tags> --accept "criterion" --test "[unit] ..."
#   ... build in the worktree it prints ...
bin/ship <task-slug> -m "Commit message"
```

`bin/task begin` runs steps 1-3 (create → `agent-worktree new` → `bind-task` →
`move building` → `session-preflight`) and prints the worktree path, port, and
task URL. `bin/ship`, run from that worktree, runs steps 5-6 (commit →
`bin/fast-check` → push → **non-draft** PR into `accepted` led by the task URL →
record `pr_url` → `bin/dor-check` → `move submitted` → read-back verify).
Re-running either after a failure **resumes** — each skips the steps already
durably recorded. Mechanics: `docs/agents/modules/devops-task-board.md`.

**What the wrappers do NOT do — read before trusting them:**

- They change **no gate semantics**. Every gate still runs and still owns its
  verdict; the wrappers only sequence the steps.
- `bin/ship` **stops at `submitted`**. It never merges, never deploys, never
  touches `release`/`main`.
- `bin/ship` has **no `--steal`**. Take a held task over with `bin/task begin
  <task-slug> --steal`, then ship.
- **You still write the tests** (step 4). Neither wrapper invents test tiers.
- `bin/ship` is **not** `bin/release ship`. `bin/release ship` is the **G4
  production deploy** (`release → main`, ship-authority only); `bin/ship` pins
  base `accepted` and stops at the `submitted` seam.
- `begin` passes `--root <worktree>` to `bin/session-preflight`, and the
  preflight self-defends that the inspected root is the task's own desk — so its
  verdict describes the worktree it just created, not the primary checkout.

Use the long form when the fast lane does not cover the case: multi-repo tasks,
a bespoke PR body, a task someone else created and shaped, or any single step
you need to rerun piecemeal.

### The long form (fallback)

Before editing a single file:

1. **Create the production task** (`bin/task create`, or the board UI at
   https://mcritchie.studio) with `kind` and `shape`. The `shape` auto-selects
   the tests you must write (`config/feature_shapes.yml`): `ui-only`
   (copy/styling) · `ui+db` (UI that persists) · `backend` (job/service, no UI)
   · `library` (studio-engine / solana-studio) · `onchain` (turf-vault /
   `Solana::*`) · `onchain-vertical` (wallet+DB+UI+program).
2. **Allocate an isolated worktree** (`bin/agent-worktree new <app> <task>`) on
   an allocated port. Do not edit on a primary checkout.
3. **Run `bin/session-preflight <task>`** from the worktree before editing. Fix
   branch drift, latest blocker feedback, generated-doc drift, stale terminology,
   or PR overlap it reports before spending implementation time.

While building:

4. Write the **test tiers your shape requires as you go**, unit-first — this is
   how bugs get caught before PR, not after. Record them tier-tagged:
   `bin/task update <task> --checks "[unit] ..." --checks "[integration] ..."`.
   For a **bug**, write the failing regression test FIRST, at the lowest tier
   that reproduces it.

Before handoff:

5. Certify — the task's **G1 Cert** gate
   (`mcritchie-studio/docs/agents/modules/gates/g1-cert.md`): commit, then run
   `bin/fast-check <task>` (the builder default — diff-mapped tests + core
   spine + rubocop on changed files, ~1 min) or `bin/full-suite-check <task>`
   (CI-independent).
6. Push, open a PR **into `accepted`** (base `accepted`, not `release`/`main`)
   whose body **leads with the task URL**, then verdict: run **`bin/dor-check
   <task>`** and fix whatever it flags — it refuses an under-tested PR and its
   verdict closes the gate. Then `bin/task move <task> submitted` **without
   waiting for CI**: a pending CI is a loud suggestion (the fast cert is credited
   provisionally), a red CI still blocks, and the authoritative CI verdict is
   review's gate-zero — `pr-review`'s supervisor bounces a red-CI task back
   with the failing checks named before any reviewer spawns.

The task lifecycle is two workflows (full spec:
`docs/agents/system/devops-cycle-design.md`), and the code walks a three-rung
branch ladder — **`accepted` → `release` → `main`**:

- **Build** (feature agent) — `designed → building → submitted`. You own
  `designed` through `submitted` (the seam); opening the PR (base `accepted`)
  hands off to DevOps.
- **Deploy** (DevOps) — `submitted → reviewed → assembled → shipped`. Every repo
  keeps persistent `accepted` and `release` branches (feature PRs target
  **`accepted`**, never `release`/`main`). Review **merges the feat PR into
  `accepted`**: on a merge-ready verdict `pr-review` `gh pr merge`s it, stamps
  `merged: "accepted"`, then moves the task `reviewed` (invariant: `reviewed` ⟺
  code-on-`accepted`; a merge failure leaves it `submitted`, a mis-based PR
  self-heals by retargeting to `accepted`) — or `bin/task block <task> --kind
  rework --feedback "…"` (back to you). Review still never touches `release`/
  `main` and never deploys. Steffon's self-healing `qa-release` sweep
  (`bin/release prepare`) then **promotes ALL of `accepted` onto `release` via
  ONE batch PR per repo** (`--base release --head accepted`, not N per-task
  merges), records `reviewed` members + `assembled` stragglers (re-stamping
  `merged: "release"`; a `reviewed` member with no `merged` stamp is a HELD
  anomaly, left behind), deploys QA, and flips members `assembled` only on
  **QA-green**. Avi's `production-deploy` (`bin/release ship`) fast-forwards
  each repo's `release → main` (stamping `merged: "main"`) → `shipped`.
- **`blocked`** is the "not in the pipeline's court" side state (env blocker, QA
  rework, or a dependency); **`archived`** is terminal.

**The branded testing gates (G1–G4).** The pipeline's test verdicts are
recorded as four attempt-aware gates: **G1 Cert** (the builder's
certification — fast/full cert + the dor-check verdict, closed at submit even
with CI still pending) → **G2 Review** (the authoritative CI verdict — the
supervisor's pre-spawn CI check plus the primary + light review lanes; the
primary's gate-zero is `bin/dor-check <task> --gate-role review`, strict on
red/pending CI) → **G3 Candidate** (Steffon's pre-QA suite + QA deploy,
release-grain) → **G4 Ship** (Avi's frozen-SHA gate + prod deploy,
release-grain, self-gated against G3). Task gates render on the task's gates
card; release gates as the /deployments G3/G4 columns. Each gate's standalone
SOP lives in `mcritchie-studio/docs/agents/modules/gates/`.

**Sizing the work — the po/dev/actual trio.** Avi is the default sizer: he sets
`po_size` when he creates and grooms the task (`bin/task create … --po-size
small|medium|large|xl`). It is a forecast, **not** a hard gate — a task can be
created without one and backfilled later (`bin/task update <task> --po-size …`).
The per-task Pokémon stamps its own `dev_size` as it CLAIMS the task (`bin/task
move <task> building --dev-size <size>`; optional). At ship, `actual_size`
**auto-derives** from the task's MEASURED $cost (sum of `cost` across its
TaskEvents, bucketed by `Task::ACTUAL_SIZE_COST_THRESHOLDS`) — only when blank,
never clobbering a manual size. (Cost, not tokens: the token total is ~98%
cache_read and pinned everything to XL.) The trio (PO forecast vs. dev forecast vs. measured
actual) powers the sizing intelligence dashboard.

**The task slug is the genesis.** Creating it in step 1 trickles down to
everything: the worktree (bound by slug), the task URL
(`https://mcritchie.studio/tasks/<slug>`), and the terminal feature indicator —
`bin/task` writes the active-feature marker the status line reads (a worktree
session overrides it via its own `.agent-context.json`). **Announce it every
session, not on request:** open with one line — `<app-slug> · <feature-slug> ·
<task URL>` — so the active feature is visible in any tool (Claude's status bar,
Codex's output; the terminal auto-links the URL), and restate the task URL at
handoff.

**Never** push to `main`, merge, deploy, or publish gems unless Mr. McRitchie
assigns you that lane in this session. Full SOP + the two-workflow release model:
`mcritchie-studio/docs/agents/system/devops-cycle-design.md`.

## Default Operating Context

Assume Mr. McRitchie starts agent sessions from `/Users/alex/projects`, and
that a plain feature request should be enough context to begin. Steps 4-6 below
are collapsed by `bin/task begin`, and step 10 by `bin/ship` — prefer those (see
**DevOps Routing** above, including their limits). The flow is written out here
so the fallback path, and what each wrapper is accountable for, stay legible.
The default launch flow is:

1. Read this file, then `mcritchie-studio/docs/ECOSYSTEM.md`.
2. Identify the target repo and read its README/RUNBOOK/topic docs relevant to
   the request.
3. Pull/check `main` and inspect git status before editing.
4. If the work is a feature, bug, QA, release, cleanup, or active-doc change,
   create or update a production McRitchie Studio task-board item before
   implementation (see **DevOps Routing** above — no size exemption). Record
   `devops["kind"]`, `devops["shape"]` (classifies the required tests),
   acceptance criteria, affected repos, risk tags, expected checks in
   `devops["test_plan"]`, and `devops["worktree_slug"]`. **Naming discipline
   (enforced by the create API):** the **title is 3-5 words** and the slug
   derives from it (the readable `/tasks/<slug>` URL; seeds `worktree_slug` +
   `feat/<slug>` — pass `--slug` only to override); **each acceptance bullet is
   5-12 words**. Put verbose detail/reasoning in `--agent-context` (free-form,
   for agent-to-agent communication). Move the task to `building` once the agent
   starts work.
5. If the task will change code or active docs, allocate an isolated worktree
   from McRitchie Studio and work there. Keep the primary checkout stable for
   integration, review, and deploys. Bind the generated production task URL to
   the worktree with `bin/agent-worktree bind-task <app> <worktree-slug> <task-slug-or-url>`
   so `whereami`, terminal context, snapshots, and PR bodies can lead from the
   task record.
6. Run `bin/session-preflight <task-slug>` from the worktree before editing; it
   surfaces latest task feedback, release-branch drift, PR state, same-file PR
   overlap, generated-doc drift, stale terminology, and required test tiers.
7. Use the managed port ranges: McRitchie Studio `3000-3099`, Turf Monster
   `3100-3199`, Tax Studio planned at `3200-3299`, Rolio reserved at
   `3300-3399`, and Chain Ops planned at `3400-3499`.
8. Build the feature and, before opening the PR, mark any inspectable local UI
   or workflow as waiting on Mr. McRitchie's approval:
   `bin/task update <task-slug> --local-url http://localhost:<port>/<path>
   --approval waiting`. In chat, return `Local Demo:
   http://localhost:<port>/<path>` as a top-level line. For email/auth flows,
   also return `Local Inbox: http://localhost:<port>/_studio/local_emails`.
   Waiting-approval tasks float to the top of their stage and pulse on the board.
9. If behavior, workflow, env vars, ports, auth, email, deploys, or agent
   operations change, update the owning active docs in the same pass.
10. Commit and push the feature branch, and run `bin/agent-worktree finish
   <app> <task-slug>` to prepare PR/QA handoff. With the PR open, run
   `bin/dor-check <task-slug>` and resolve anything it flags. Update the task
   with branch, PR URL, local URL, tier-tagged `devops["checks_run"]` (e.g.
   `[unit] ...`, `[integration] ...`), and any changed acceptance criteria,
   then move it to `submitted` — do not wait for CI (review's gate-zero owns
   the CI verdict; a red CI bounces the task back). Handoffs should include
   the task URL before the PR URL. Deploy or merge only when Mr. McRitchie
   assigned that lane or the task explicitly includes production rollout.

For a new feature session, Mr. McRitchie should only need to say the target app
and the feature. A good prompt is:

```text
Work from /Users/alex/projects. Build this feature in <app>: <feature>.
Use the fast lane: bin/task begin --title "Three To Five Words" --repo <app>
--kind feature --shape (ui-only|ui+db|backend|library|onchain|onchain-vertical)
--risk <tags> --accept "<criterion>" --test "<tier>". It creates the task,
allocates the isolated worktree on an allocated port, claims the task, and
preflights (pinning the worktree via --root). Read the preflight output and fix
any blockers before implementation.
Write the test tiers your shape requires as you go (unit-first); record them
tier-tagged in devops["checks_run"]. Before PR handoff, mark local validation
with `bin/task update <task> --local-url http://localhost:<port>/<path>
--approval waiting`, return `Local Demo: http://localhost:<port>/<path>` in
chat, and wait for approval or requested changes. Update docs if behavior
changes. Then hand off with bin/ship <task> -m "<commit message>" from the
worktree — it commits, certifies, pushes, opens the non-draft PR into accepted
led by the task URL, runs bin/dor-check, and moves the task to submitted
without waiting for CI (review's gate-zero owns the CI verdict). Fall back to
the long-form commands if the task spans repos or needs a bespoke PR body.
Do not merge or deploy unless I explicitly assigned that lane.
```

## Start Here

| Need | Read |
|------|------|
| Ecosystem map | `mcritchie-studio/docs/ECOSYSTEM.md` |
| Fresh-machine rebuild | `mcritchie-studio/docs/agents/system/house-burn-down.md` |
| Ecosystem build script | `mcritchie-studio/docs/agents/system/ecosystem-build.md` |
| Agent culture | `mcritchie-studio/docs/agents/modules/culture.md` |
| Credentials and 1Password | `mcritchie-studio/docs/agents/modules/credentials.md` |
| Credential item names | `mcritchie-studio/docs/agents/modules/credential-inventory.md` |
| Shared email operations | `mcritchie-studio/docs/agents/modules/email-operations.md` |
| Managed app registry | `mcritchie-studio/docs/agents/modules/app-registry.md` |
| New app onboarding (tiers + SOP) | `mcritchie-studio/docs/agents/system/new-app-onboarding-sop.md` |
| Ports, servers, callbacks | `mcritchie-studio/docs/agents/modules/ports-and-processes.md` |
| Parallel DevOps and QA graduation | `mcritchie-studio/docs/agents/modules/parallel-agent-devops.md` |
| Modular PR review SOP | `mcritchie-studio/docs/agents/modules/pr-review-sop.md` |
| Zap protocol (small mid-cycle fixes, no new task) | `mcritchie-studio/docs/agents/modules/zap-protocol.md` |
| Heartbeats (three soul launchers) | `mcritchie-studio/docs/agents/modules/heartbeats.md` |
| Avi heartbeat launcher | `mcritchie-studio/docs/agents/agents/avi/HEARTBEAT.md` |
| Avi production deploy SOP | `mcritchie-studio/docs/agents/agents/avi/sops/production-deploy.md` |
| Avi PR review SOP (supervisor) | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review.md` |
| Avi slow PR review SOP | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-slow.md` |
| Avi primary reviewer role SOP | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-primary.md` |
| Avi light reviewer role SOP | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-light.md` |
| Avi deploy with task SOP | `mcritchie-studio/docs/agents/agents/avi/sops/deploy-with-task.md` |
| Steffon heartbeat launcher | `mcritchie-studio/docs/agents/agents/steffon/HEARTBEAT.md` |
| Steffon QA release SOP | `mcritchie-studio/docs/agents/agents/steffon/sops/qa-release.md` |
| Steffon archive shipped SOP | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| Alex heartbeat launcher | `mcritchie-studio/docs/agents/agents/alex/HEARTBEAT.md` |
| Alex grade events SOP | `mcritchie-studio/docs/agents/agents/alex/sops/grade-events.md` |
| Alex share insights SOP | `mcritchie-studio/docs/agents/agents/alex/sops/share-insights.md` |
| Alex full cycle SOP | `mcritchie-studio/docs/agents/agents/alex/sops/full-cycle.md` |
| Alex clean up SOP (board → 0 + infra sweep) | `mcritchie-studio/docs/agents/agents/alex/sops/clean-up.md` |
| DevOps task-board handoff | `mcritchie-studio/docs/agents/modules/devops-task-board.md` |
| Fast lane (`bin/task begin` / `bin/ship`) | `mcritchie-studio/docs/agents/modules/devops-task-board.md` |
| Task-board API (auth + contract) | `mcritchie-studio/docs/agents/modules/task-board-api.md` |
| Parallel agents and worktrees | `mcritchie-studio/docs/agents/modules/worktrees.md` |
| LLM adapter policy | `mcritchie-studio/docs/agents/modules/llm-adapters.md` |
| Codex runtime updates | `mcritchie-studio/docs/agents/modules/codex-updates.md` |
| Backend discipline | `mcritchie-studio/docs/agents/modules/backend-discipline.md` |
| Tests | `mcritchie-studio/docs/agents/modules/testing.md` |
| G1 Cert gate (builder certification) | `mcritchie-studio/docs/agents/modules/gates/g1-cert.md` |
| G2 Review gate (primary + light lanes) | `mcritchie-studio/docs/agents/modules/gates/g2-review.md` |
| G3 Candidate gate (pre-QA + QA deploy) | `mcritchie-studio/docs/agents/modules/gates/g3-candidate.md` |
| G4 Ship gate (frozen-SHA + prod deploy) | `mcritchie-studio/docs/agents/modules/gates/g4-ship.md` |
| Deploys | `mcritchie-studio/docs/agents/modules/deployment.md` |
| Keeping docs clean | `mcritchie-studio/docs/agents/modules/docs-maintenance.md` |
| Memory maintenance | `mcritchie-studio/docs/agents/modules/memory-maintenance.md` |
| Result distillation (findings not raw ops) | `mcritchie-studio/docs/agents/modules/result-distillation.md` |
| Communication style (reporting to Mr. McRitchie) | `mcritchie-studio/docs/agents/modules/communication-style.md` |
| Audit playbook | `mcritchie-studio/docs/agents/modules/audit-playbook.md` |
| Shared SES production proof | `mcritchie-studio/docs/agents/audits/ses-production-proof-2026-06-14.md` |
| Current final closeout | `mcritchie-studio/docs/agents/audits/final-closeout-2026-06-17.md` |
| Session retrospective | `mcritchie-studio/docs/agents/audits/session-retrospective-2026-06-17.md` |
| Prior final audit | `mcritchie-studio/docs/agents/audits/fresh-final-audit-2026-06-15.md` |
| Prior ecosystem closeout | `mcritchie-studio/docs/agents/audits/final-closeout-2026-06-14.md` |
| Latest ecosystem audit | `mcritchie-studio/docs/agents/audits/broader-ecosystem-audit-2026-06-14.md` |
| Delete later ledger | `mcritchie-studio/docs/agents/maintenance/delete-later.md` |
| Parking lot (kept, not on the board) | `mcritchie-studio/docs/agents/maintenance/parking-lot.md` |

## SOP Registry

This table repeats the top-level SOP registry for agents that jump straight to
the reference section. SOP invocations are plain text prompts, not installed
skills. When Mr. McRitchie says one of these phrases, read the owning soul's
`HEARTBEAT.md` when the phrase is a heartbeat launcher, then read the specific
SOP file linked below. A heartbeat may set agent attribution and choose the act
order, then it references the SOP. The SOP files are independent and do not
depend on the heartbeat.

| Invocation | Owner | Read |
|------------|-------|------|
| `Avi Heartbeat` | Avi | `mcritchie-studio/docs/agents/agents/avi/HEARTBEAT.md` |
| `production-deploy` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/production-deploy.md` |
| `pr-review` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review.md` |
| `pr-review-slow` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-slow.md` |
| `pr-review-primary` (role SOP) | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-primary.md` |
| `pr-review-light` (role SOP) | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/pr-review-light.md` |
| `deploy-with-task` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/deploy-with-task.md` |
| `Steffon Heartbeat` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/HEARTBEAT.md` |
| `archive-shipped` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| `archive-completed` (legacy alias) | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| `qa-release` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/qa-release.md` |
| `qa-deploy` (legacy alias) | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/qa-release.md` |
| `Alex Heartbeat` | Alex | `mcritchie-studio/docs/agents/agents/alex/HEARTBEAT.md` |
| `grade-events` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/grade-events.md` |
| `share-insights` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/share-insights.md` |
| `full-cycle` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/full-cycle.md` |
| `clean-up` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/clean-up.md` |

## Repos

| Repo | Role | Local port |
|------|------|------------|
| `mcritchie-studio` | Flagship hub, SSO source, recovery scripts, agent docs | 3000 |
| `turf-monster` | Sports pick'em satellite, payments, Solana integration | 3100 |
| `rolio` | Release-managed standalone with reserved satellite range | 3300 |
| `chain-ops` | Planned Solana localnet/QA/node operations control plane | 3400 |
| `studio-engine` | Shared Rails engine for auth, theme, error logs, SSO | none |
| `solana-studio` | Ruby Solana primitives | none |
| `turf-vault` | Anchor smart contract | none |

## Session Shape

1. Read this file first.
2. Read only the modules relevant to the task.
3. Check git status before editing.
4. If editing code or active docs, create or enter the task worktree first.
5. Make scoped changes in the correct repo or worktree.
6. Run meaningful verification yourself.
7. Hand back something inspectable: local URL, screenshot, test output summary, diff summary, or explicit blocker.
8. Update docs when behavior or workflow changes.

## Parallel Work Quick Start

> **Concurrency cap — 5 at a time.** Cap parallel work at **5 concurrent
> operations per session** — at most 5 agents / `heroku run` dynos / parallel
> board-writing commands in flight at once. The prod board Postgres (essential-0)
> has a **20 hard-connection limit**, and a heavy fan-out (parallel review agents +
> the ship's `heroku run` dynos + `bin/task`/`bin/release` CLI + web/worker pools)
> once spiked past it → `FATAL: too many connections` → the board briefly 500'd.
> Parallelism stays first-class (fan-out is still the default for devops) — just
> **bounded**: fan out reviews and any other batch in **waves of ≤5**, never all at
> once; when a queue is larger than 5, run it in successive waves.

For feature work, active-doc edits, or any task that might be committed, start
from McRitchie Studio, create or update the task-board item, then allocate a
worktree:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task begin --title "Three To Five Words" --repo turf-monster --shape <shape>
bin/agent-worktree up turf-monster task-slug     # only when you need a live stack
bin/ship task-slug -m "Commit message"           # from the worktree, at handoff
```

`bin/task begin` covers create + `new` + `bind-task` + `move building` +
`session-preflight` (see **DevOps Routing** above for what it does NOT do). The
long form stays available for multi-repo work and piecemeal reruns:

```bash
bin/agent-worktree plan turf-monster task-slug
bin/agent-worktree new turf-monster task-slug
bin/agent-worktree bind-task turf-monster task-slug task-abc123def456
bin/session-preflight task-slug
bin/agent-worktree up turf-monster task-slug
bin/agent-worktree finish turf-monster task-slug
```

Return the printed `http://localhost:<port>` URL in the handoff.

Every feature or bug cycle must have a production McRitchie Studio task before
code or active-doc edits start. Keep the **title 3-5 words** (the slug derives
from it — the readable task URL — and seeds `metadata["devops"]["worktree_slug"]`
+ the `feat/<slug>` branch; `--slug` overrides) and **each acceptance bullet
5-12 words**; verbose detail goes in `devops["agent_context"]`. Bind the task
URL to the worktree.
Use `metadata["devops"]` to record affected repos, branch, PR URL, local URL,
QA URL, production URL when deployed, release slug, risk tags, acceptance
criteria, test plan, checks run in `devops["checks_run"]`, and
`approval_status` when waiting for Mr. McRitchie's local validation.
`bin/qa-intake` helps Avi discover PR/worktree state, but it does not replace
the task-board record.

Primary checkouts are for reading, status checks, integration, and deployment.
Do not commit task work from a primary checkout unless you are explicitly acting
as the deploy owner. If a primary checkout becomes dirty or moves while you are
working, report the changed floor and continue from your worktree.

For local validation chat, use exact top-level labels so Mr. McRitchie never has
to hunt through prose:

```text
Task: https://mcritchie.studio/tasks/<task-slug>
Magic Link: http://localhost:<port>/l/<token>
Local Demo: http://localhost:<port>/<path>
```

`Magic Link:` is a minted sign-in link that lands on the page under review
(single-use, 12-hour TTL for reviews) — the recipe lives in
`mcritchie-studio/docs/agents/modules/communication-style.md`. `Local Demo:`
stays the plain path: it is the durable fallback and what `--local-url`
records on the task.

For email or auth flows, also return the printed local inbox:

```text
Local Inbox: http://localhost:<port>/_studio/local_emails
```

Worktree stacks default to `LOCAL_EMAIL_CAPTURE=1`, so magic links and other emails are recorded there instead of sent to real inboxes.

Feature work graduates through PR/QA, not direct `main` pushes. Use
`bin/agent-worktree finish <app> <task-slug> --push --pr` when the branch is
ready for Avi review. The same handoff must update the task with the branch,
PR URL, local URL, and `devops["checks_run"]`, then move the task to
`submitted`. Keep the worktree and branch until Avi confirms the PR was merged
or intentionally abandoned.

For a dedicated review/QA session, use the recurring QA intake prompt in
`mcritchie-studio/docs/agents/modules/parallel-agent-devops.md`. That cycle
stops after QA deployment; production rollout needs a separate explicit prompt
(`production-deploy`, or Alex's ship-authority `full-cycle`).
The conductor queue starts with:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster,rolio
```

The command joins open GitHub PRs to the local worktree registry and labels
items as `avi-ready`, `avi-ready-draft`, `checks-review`, `merge-risk`,
`needs-agent`, `missing-local-branch`, or `ready-to-open-pr`. Each queue item
also prints an `action:` line; use it as the next owner handoff.

QA servers, once provisioned, are operated with `mcritchie-studio/bin/qa-server`.
They are release-candidate targets for Mr. McRitchie review before production;
production deploy remains separately ship-authority gated.

Before reusing or deleting worktrees, inspect lifecycle state:

```bash
bin/agent-worktree list
bin/agent-worktree doctor
bin/agent-worktree snapshot --write
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster,rolio
bin/agent-worktree cleanup
bin/agent-worktree cleanup --reclaim [--yes]
bin/agent-worktree remove <app> <task-slug> --yes
```

`snapshot --write` refreshes the local non-secret worktree registry at
`/Users/alex/projects/.agents/worktree-registry.json` for QA/conductor
sessions. `cleanup` is dry-run only; `cleanup --write` only appends candidates
to the delete-later ledger. Actual removal stays approval-gated and should use
`bin/agent-worktree remove <app> <task-slug> --yes` so stack stop, ledger
update, Git worktree removal, local branch deletion, and registry refresh happen
together. `cleanup --reclaim` is the scale-down-on-close batch flow: the dry run
lists every worktree SAFE to auto-release (clean + merged/main-equivalent, never
the primary) with its Redis DB, and `cleanup --reclaim --yes` runs that same full
`remove` teardown for each candidate, then shrinks the Redis band toward the
floor. See `mcritchie-studio/docs/agents/modules/worktrees.md`.

The worktree launcher uses an elastic Redis band starting at DB `9`. The band
idles at `20` slots, auto-grows by `10` (restart-free) when full while physical
room remains, and auto-shrinks by `10` (never below `20`) as worktrees close
(`remove`, `cleanup --write`, and `cleanup --reclaim --yes` all trigger the
shrink).
Physical capacity is the Redis `databases` setting, fixed at startup; the band
can never exceed it. Inspect both with `bin/agent-worktree scale status`. If the
band is capped by physical room, run `bin/agent-worktree scale --provision` once
to raise Redis `databases` (this restarts Redis and bounces every running stack;
leave it for the QA/infra lane).

## LLM Adapters

A generated root `CLAUDE.md` adapter is required because Claude Code auto-loads
that file, not `AGENTS.md`. Keep it thin: inline the DevOps gate, then `@AGENTS.md`.
Do not create root `CODEX.md`; Codex reads `AGENTS.md` natively. See
`mcritchie-studio/docs/agents/modules/llm-adapters.md`.
