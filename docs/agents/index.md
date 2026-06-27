# McRitchie Agent Entry

This is the canonical source for the generated projects-root `AGENTS.md`.
McRitchie Studio owns this file so the agent operating model survives a wiped local machine and can be restored from GitHub.

Paths below are written for the generated file at `/Users/alex/projects/AGENTS.md`.

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
- A pushed feature branch preserves code. `main` is for reviewed integration,
  not backup. Feature agents push their own branch and graduate through PR/QA;
  Avi or the designated release conductor merges.

## DevOps Routing — read before writing ANY code

If your work will produce a code diff — a feature, a bug, or a chore, **even a
"small" one** — you are a Feature agent and you follow the cycle. There is **no
size exemption**: "it's just a small change" is exactly when this gets skipped.

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

5. Run **`bin/dor-check <task>`** and fix whatever it flags — it refuses an
   under-tested PR.
6. Commit on the feature branch, push, open a PR **into `release`** (base
   `release`, not `main`) whose body **leads with the task URL**, then
   `bin/task move <task> submitted`.

The task lifecycle is two workflows (full spec:
`docs/agents/system/devops-cycle-design.md`):

- **Build** (feature agent) — `designed → building → submitted`. You own
  `designed` through `submitted` (the seam); opening the PR hands off to DevOps.
- **Deploy** (DevOps) — `submitted → reviewed → assembled → shipped`. Every repo
  keeps a **persistent `release` branch** (feature PRs target it, never `main`).
  QA reviews the submitted PR → `reviewed` (approved) or `bin/task block <task>
  --kind rework --feedback "…"` (back to you). Approved PRs are then **merged
  into `release`** — which flips the task to `assembled` (`bin/release merge
  <task>`); the conductor deploys `origin/release` to QA (`bin/release prepare`)
  and ships by fast-forwarding each repo's `release → main` (`bin/release ship`)
  → `shipped`.
- **`blocked`** is the "not in the pipeline's court" side state (env blocker, QA
  rework, or a dependency); **`archived`** is terminal.

**Sizing the work — the po/dev/actual trio.** Avi is the default sizer: he sets
`po_size` when he creates and grooms the task (`bin/task create … --po-size
small|medium|large|xl`). It is a forecast, **not** a hard gate — a task can be
created without one and backfilled later (`bin/task update <task> --po-size …`).
The per-task Pokémon stamps its own `dev_size` as it CLAIMS the task (`bin/task
move <task> building --dev-size <size>`; optional). At ship, `actual_size`
**auto-derives** from the task's MEASURED usage (total tokens across its
TaskEvents, bucketed by `Task::ACTUAL_SIZE_THRESHOLDS`) — only when blank, never
clobbering a manual size. The trio (PO forecast vs. dev forecast vs. measured
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
that a plain feature request should be enough context to begin. The default
launch flow is:

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
   `3100-3199`, Tax Studio reserved at `3200-3299`, next app `3300-3399`.
8. Build the feature, run the meaningful tests/checks, and give Mr. McRitchie a
   local URL to react to.
9. If behavior, workflow, env vars, ports, auth, email, deploys, or agent
   operations change, update the owning active docs in the same pass.
10. Run `bin/dor-check <task-slug>` and resolve anything it flags. Then commit
   and push the feature branch, and run `bin/agent-worktree finish <app>
   <task-slug>` to prepare PR/QA handoff. Update the task with branch, PR URL,
   local URL, tier-tagged `devops["checks_run"]` (e.g. `[unit] ...`,
   `[integration] ...`), and any changed acceptance criteria, then move it to
   `submitted`. Handoffs should include the task URL before the PR URL. Deploy
   or merge only when Mr. McRitchie assigned that lane or the task explicitly
   includes production rollout.

For a new feature session, Mr. McRitchie should only need to say the target app
and the feature. A good prompt is:

```text
Work from /Users/alex/projects. Build this feature in <app>: <feature>.
Create the production McRitchie Studio task FIRST with kind=feature, the shape
(ui-only|ui+db|backend|library|onchain|onchain-vertical), acceptance criteria,
affected repos, risk tags, and expected checks in devops["test_plan"]. Use an
isolated worktree and allocated port before editing. Run bin/session-preflight
<task> from the worktree and fix any blockers it reports before implementation.
Write the test tiers your shape requires as you go (unit-first); record them
tier-tagged in devops["checks_run"]. Give me a local URL to review and update
docs if behavior changes. Before handoff run bin/dor-check <task> and fix what
it flags, then commit, push the branch, open a PR led by the task URL, and move
the task to submitted for Avi QA. Do not merge or deploy unless I explicitly
assigned that lane.
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
| DevOps task-board handoff | `mcritchie-studio/docs/agents/modules/devops-task-board.md` |
| Task-board API (auth + contract) | `mcritchie-studio/docs/agents/modules/task-board-api.md` |
| Parallel agents and worktrees | `mcritchie-studio/docs/agents/modules/worktrees.md` |
| LLM adapter policy | `mcritchie-studio/docs/agents/modules/llm-adapters.md` |
| Backend discipline | `mcritchie-studio/docs/agents/modules/backend-discipline.md` |
| Tests | `mcritchie-studio/docs/agents/modules/testing.md` |
| Deploys | `mcritchie-studio/docs/agents/modules/deployment.md` |
| Keeping docs clean | `mcritchie-studio/docs/agents/modules/docs-maintenance.md` |
| Memory maintenance | `mcritchie-studio/docs/agents/modules/memory-maintenance.md` |
| Audit playbook | `mcritchie-studio/docs/agents/modules/audit-playbook.md` |
| Shared SES production proof | `mcritchie-studio/docs/agents/audits/ses-production-proof-2026-06-14.md` |
| Current final closeout | `mcritchie-studio/docs/agents/audits/final-closeout-2026-06-17.md` |
| Session retrospective | `mcritchie-studio/docs/agents/audits/session-retrospective-2026-06-17.md` |
| Prior final audit | `mcritchie-studio/docs/agents/audits/fresh-final-audit-2026-06-15.md` |
| Prior ecosystem closeout | `mcritchie-studio/docs/agents/audits/final-closeout-2026-06-14.md` |
| Latest ecosystem audit | `mcritchie-studio/docs/agents/audits/broader-ecosystem-audit-2026-06-14.md` |
| Delete later ledger | `mcritchie-studio/docs/agents/maintenance/delete-later.md` |

## Repos

| Repo | Role | Local port |
|------|------|------------|
| `mcritchie-studio` | Flagship hub, SSO source, recovery scripts, agent docs | 3000 |
| `turf-monster` | Sports pick'em satellite, payments, Solana integration | 3100 |
| `chain-ops` | Planned Solana localnet/QA/node operations control plane | 3300 |
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
QA URL, production URL when deployed, release train, risk tags, acceptance
criteria, test plan, and checks run in `devops["checks_run"]`. `bin/qa-intake`
helps Avi discover PR/worktree state, but it does not replace the task-board
record.

Primary checkouts are for reading, status checks, integration, and deployment.
Do not commit task work from a primary checkout unless you are explicitly acting
as the deploy owner. If a primary checkout becomes dirty or moves while you are
working, report the changed floor and continue from your worktree.

For email or auth flows, also return the printed local inbox:

```text
http://localhost:<port>/_studio/local_emails
```

Worktree stacks default to `LOCAL_EMAIL_CAPTURE=1`, so magic links and other emails are recorded there instead of sent to real inboxes.

Feature work graduates through PR/QA, not direct `main` pushes. Use
`bin/agent-worktree finish <app> <task-slug> --push --pr` when the branch is
ready for Avi review. The same handoff must update the task with the branch,
PR URL, local URL, and `devops["checks_run"]`, then move the task to
`submitted`. Keep the worktree and branch until Avi confirms the PR was merged
or intentionally abandoned.

For a dedicated review/merge/QA session, use the recurring QA intake prompt in
`mcritchie-studio/docs/agents/modules/parallel-agent-devops.md`. That cycle
stops after QA deployment; production rollout needs a separate explicit prompt
such as `Merge, Assemble, Deploy`.
The conductor queue starts with:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster
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
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster
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
