# McRitchie Agent Entry

The map every session loads (source: `mcritchie-studio/docs/agents/index.md`). Read
it once, then drill into the page your work needs; each rule is one line with a link
to its detail. The long form it replaced is frozen verbatim in
`mcritchie-studio/docs/agents/archive/entry-docs-2026-09-24.md`.

## Who is who

Alex is the human owner. Xan is the orchestrator agent.

| Soul | Seat | Soul docs |
|------|------|-----------|
| Pokémon | The general builder. Every task gets its own mascot; it builds the whole task to `submitted` | `docs/agents/agents/pokemon/` |
| Xan | Orchestrator; runs focus sessions; the documentation reviewer | `docs/agents/agents/xan/` |
| Carl | Lead Architect; primary reviewer of code PRs; merges into `accepted` | `docs/agents/agents/carl/` |
| Shannon · Jasper | Review lights for UI · on-chain | `docs/agents/agents/<soul>/` |
| Avi | Product owner; runs `qa-release`; arbitrates contested blocks | `docs/agents/agents/avi/` |
| Steffon | Infrastructure light; runs `production-deploy`, credentials, desks | `docs/agents/agents/steffon/` |
| Turf Monster | The Turf Monster app's operator: scores, contests, markets | `docs/agents/agents/turf_monster/` |
| Rex · Mason · Mack | Marketing strategy (CMO) · brand voice and launches · general worker | `docs/agents/agents/<soul>/` |

## SOP Invocation Standard

SOPs are first-class registered commands in this workspace. The set is finite,
the names are stable, and every SOP name maps to a repo file. Do not treat an SOP
name as ordinary prose, generic GitHub triage, or a broad workflow request.
McRitchie operating procedures are normal repo docs, not installed skills.

- Heartbeats live at `mcritchie-studio/docs/agents/agents/<agent>/HEARTBEAT.md`.
- Agent-specific SOPs live at `mcritchie-studio/docs/agents/agents/<agent>/sops/<sop>.md`.
- Shared primitives live under `mcritchie-studio/docs/agents/modules/`.

When Alex names one (`pr-review`, `qa-release`, `production-deploy`, `focus-session`,
`clean-up`, …), open your activity, resolve it in the registry tables at the end of
this map, and read the mapped HEARTBEAT.md or SOP file before queue inspection,
`--help` probing, GitHub PR discovery, or tool/plugin selection. Then execute it.
Each SOP stands alone; a design doc is background, never an execution path.

## The pipeline

```text
Alex + focus session ──▶ Pokémon builder ──PR green──▶ reviewer ──merge──▶ (accepted)
  (holds the epic plan)   desk · build · ship ◀─blocker─┘  Carl for code; Xan for prose*
(accepted) ──Avi runs qa-release──▶ release, QA green ──Steffon runs production-deploy──▶ (main)
                                                         within Alex's 30-minute window
```

- \* Xan alone reviews prose only on the focus-session path. The `pr-review` sweep
  still runs Carl plus a light on every PR.
- Task stages: **Build** `designed → building → submitted` (the builder), then
  **Deploy** `submitted → reviewed → assembled → shipped`. `blocked` needs
  attention; `archived` is terminal. Code walks `accepted` → `release` → `main`.
- Alex's operator windows: 10 min for a UI approval, 20 for an escalation, 30 for
  production authority (`config/release_builder.yml`).
- Detail: `docs/agents/system/devops-v3-design.md` and `docs/agents/system/devops-cycle-design.md`.

## The commands that matter

All live in the hub, `/Users/alex/projects/mcritchie-studio/bin`. **The path picks
the SCRIPT, the cwd picks the TREE**: name the hub's script, stand in the desk.

| Command | What it does |
|---------|--------------|
| `bin/task begin --title "Three To Five Words" --agent <soul> --repo <app> --kind <kind> --shape <shape> --risk <tag> --accept "…" --test "[unit] …"` | Creates the task, cuts the desk, claims it, preflights |
| `bin/ship-wait <task-slug> --launch -m "Commit message"` | Runs `bin/ship` and waits: commit, push, PR into `accepted`, CI, `bin/dor-check`, `submitted` |
| `bin/task show <slug> -v` · `bin/task list --stage <stage>` | Read one task · read the board |
| `bin/release status` | Where the current release stands |
| `bin/agent-activity start\|next\|end` | Narrate your work (rule 1 below) |

A cold ship takes about 12 minutes, so run it in the background with `bin/ship-wait`;
do not hand-roll a pgrep watcher. `bin/fast-check` is an optional one-minute
pre-flight, and the cert gate (test-only included) reads only the PR's settled green CI.
Where each command may run, the author set, and the long form:
`docs/agents/modules/fast-lane.md`.

## First Rules

1. **Narrate.** Open a `bin/agent-activity` Explore activity before your first tool call; keep one per unit of work. Detail: `docs/agents/modules/heartbeats.md`.
2. **Task before code.** Any diff, even a small one, starts with `bin/task begin`; there is no size exemption. Detail: `docs/agents/modules/building-sop.md`.
3. **Desks, not primaries.** Edit only in your task's worktree; primary checkouts are for reading and deploys. Detail: `docs/agents/modules/worktrees.md`.
4. **GitHub auth is self-service.** On a 401, run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"`; never ask Alex for `gh auth login`. Detail: `docs/agents/modules/token-session.md`.
5. **Never merge, deploy, or push `main`** unless Alex assigned you that lane in this session. `bin/ship` stops at `submitted`.
6. **Concurrency cap: 5 at a time.** At most five agents, dynos, or board-writing commands in flight; the board database has 20 connections.
7. **No secrets in output.** Use named 1Password references and purpose-built scripts. Detail: `docs/agents/modules/credentials.md`.
8. **No terminal chores for Alex.** Run safe commands yourself; ask him only for approvals, product judgment, or a credential only he holds.

Namespace scratch writes by task slug (`ship-<task-slug>.log`); sibling agents share one scratchpad.
Correct Alex's spelling and grammar as you transcribe, by *The Elements of Style*.

## Talking to Alex

1. **Idea first:** lead with the outcome in plain words, three sentences at most.
2. **Then specifics:** a table or list with every handle: task URL, slug, path, branch, PR URL, command.
3. **Labels:** `Task:`, `Magic Link:` (the stack's `/_studio/local_review?return_to=/<path>` mint URL), `Local Demo:`, `Local Inbox:`.
4. **Name work by its task slug**; PR numbers and SHAs are plumbing.
5. **End a chat hand-back with the in-flight roster**, stamped in Denver time, even when nothing runs.

Detail: `docs/agents/modules/communication-style.md`.

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

Desks take ports from managed ranges (hub `3000-3099`): `docs/agents/modules/ports-and-processes.md`.

## Where to drill in

| When your work touches | Read |
|------------------------|------|
| Every doc, by topic (the full index) | `docs/agents/start-here.md` |
| The ecosystem | `docs/ECOSYSTEM.md` |
| **Build**: a task, from claim to `submitted` | `docs/agents/modules/building-sop.md`; command rules in `docs/agents/modules/fast-lane.md` |
| Holding an epic | `docs/agents/modules/focus-session.md` |
| The board | `docs/agents/modules/devops-task-board.md` |
| **Review**: a PR, from claim to merge | `docs/agents/agents/carl/sops/pr-review.md`; the reviewer's own steps in `docs/agents/agents/carl/sops/pr-review-primary.md` |
| **Release**: `accepted` → QA → production | `docs/agents/agents/avi/sops/qa-release.md`, `docs/agents/agents/steffon/sops/production-deploy.md`, `docs/agents/modules/gates/` |
| **Desks and infra** | `docs/agents/modules/worktrees.md` |
| Tests | `docs/agents/modules/testing.md` |
| **Credentials** and GitHub auth | `docs/agents/modules/token-session.md` (a broken session), `docs/agents/modules/source-control.md` (how auth works), `docs/agents/modules/credentials.md` (1Password) |
| **Communication**: reporting to Alex | `docs/agents/modules/communication-style.md` |
| **Learning**: grades and insights | `docs/agents/agents/xan/sops/grade-events.md` |
| History cut from a page | `docs/agents/archive/<page>-2026-09-25.md` |

## SOP Invocation Table

| Invocation | Owner | Read first |
|------------|-------|------------|
| `pr-review` | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review.md` |
| `pr-review-slow` | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-slow.md` |
| `pr-review-primary` (role SOP) | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-primary.md` |
| `pr-review-light` (role SOP) | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-light.md` |
| `Carl Heartbeat` | Carl | `mcritchie-studio/docs/agents/agents/carl/HEARTBEAT.md` |
| `qa-release` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/qa-release.md` |
| `qa-deploy` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/qa-release.md` |
| `deploy-with-task` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/deploy-with-task.md` |
| `arbitrate-block` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/arbitrate-block.md` |
| `Avi Heartbeat` | Avi | `mcritchie-studio/docs/agents/agents/avi/HEARTBEAT.md` |
| `live-score-watch` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/live-score-watch.md` |
| `contest-rehearsal` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/contest-rehearsal.md` |
| `sleeper-auction-watch` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/sleeper-auction-watch.md` |
| `entry-forfeit` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/entry-forfeit.md` |
| `market-refresh` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/market-refresh.md` |
| `content-build` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/content-build.md` |
| `roster-sync` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/roster-sync.md` |
| `Turf Monster Heartbeat` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/HEARTBEAT.md` |
| `production-deploy` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/production-deploy.md` |
| `archive-shipped` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| `archive-completed` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| `clean-infra` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/clean-infra.md` |
| `bucket-provision` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/bucket-provision.md` |
| `credential-filing` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/credential-filing.md` |
| `credential-rotation` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/credential-rotation.md` |
| `workspace-provision` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-provision.md` |
| `workspace-launch` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-launch.md` |
| `domain-purchase` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/domain-purchase.md` |
| `workspace-signup` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-signup.md` |
| `domain-dns` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/domain-dns.md` |
| `website-launch` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/website-launch.md` |
| `chrome-profiles` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/chrome-profiles.md` |
| `workspace-icon` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-icon.md` |
| `Steffon Heartbeat` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/HEARTBEAT.md` |
| `full-cycle` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/full-cycle.md` |
| `clean-up` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/clean-up.md` |
| `grade-events` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/grade-events.md` |
| `share-insights` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/share-insights.md` |
| `Xan Heartbeat` | Xan | `mcritchie-studio/docs/agents/agents/xan/HEARTBEAT.md` |
| `Alex Heartbeat` (legacy alias) | Xan | `mcritchie-studio/docs/agents/agents/xan/HEARTBEAT.md` |
| `constraint-diagnosis` | Rex | `mcritchie-studio/docs/agents/agents/rex/sops/constraint-diagnosis.md` |
| `content-sprint` | Rex | `mcritchie-studio/docs/agents/agents/rex/sops/content-sprint.md` |
| `Rex Heartbeat` | Rex | `mcritchie-studio/docs/agents/agents/rex/HEARTBEAT.md` |
| `address-blocker` | Shared | `mcritchie-studio/docs/agents/modules/address-blocker.md` |
| `building-sop` | Shared | `mcritchie-studio/docs/agents/modules/building-sop.md` |
| `focus-session` | Shared | `mcritchie-studio/docs/agents/modules/focus-session.md` |
| `process-backlog` | Shared | `mcritchie-studio/docs/agents/modules/process-backlog.md` |
| `work-backlog` | Shared | `mcritchie-studio/docs/agents/modules/work-backlog.md` |
| `token-session` | Shared | `mcritchie-studio/docs/agents/modules/token-session.md` |
| `knowledge-capture` | Shared | `mcritchie-studio/docs/agents/modules/knowledge-capture.md` |
| `slack-capture` | Shared | `mcritchie-studio/docs/agents/modules/slack-capture.md` |
| `gmail-capture` | Shared | `mcritchie-studio/docs/agents/modules/gmail-capture.md` |
| `credential-issues` | Shared | `mcritchie-studio/docs/agents/modules/credential-issues.md` |
| `form-fill` | Shared | `mcritchie-studio/docs/agents/modules/form-fill.md` |

## SOP Registry

The same registry again, for agents that jump to the reference section. A
heartbeat may set attribution and act order; the SOP files do not depend on it.

| Invocation | Owner | Read |
|------------|-------|------|
| `Carl Heartbeat` | Carl | `mcritchie-studio/docs/agents/agents/carl/HEARTBEAT.md` |
| `pr-review` | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review.md` |
| `pr-review-slow` | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-slow.md` |
| `pr-review-primary` (role SOP) | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-primary.md` |
| `pr-review-light` (role SOP) | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-light.md` |
| `Avi Heartbeat` | Avi | `mcritchie-studio/docs/agents/agents/avi/HEARTBEAT.md` |
| `qa-release` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/qa-release.md` |
| `qa-deploy` (legacy alias) | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/qa-release.md` |
| `deploy-with-task` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/deploy-with-task.md` |
| `arbitrate-block` | Avi | `mcritchie-studio/docs/agents/agents/avi/sops/arbitrate-block.md` |
| `live-score-watch` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/live-score-watch.md` |
| `contest-rehearsal` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/contest-rehearsal.md` |
| `sleeper-auction-watch` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/sleeper-auction-watch.md` |
| `entry-forfeit` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/entry-forfeit.md` |
| `market-refresh` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/market-refresh.md` |
| `content-build` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/content-build.md` |
| `roster-sync` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/sops/roster-sync.md` |
| `Turf Monster Heartbeat` | Turf Monster | `mcritchie-studio/docs/agents/agents/turf_monster/HEARTBEAT.md` |
| `Steffon Heartbeat` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/HEARTBEAT.md` |
| `production-deploy` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/production-deploy.md` |
| `archive-shipped` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| `archive-completed` (legacy alias) | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| `clean-infra` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/clean-infra.md` |
| `bucket-provision` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/bucket-provision.md` |
| `credential-filing` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/credential-filing.md` |
| `credential-rotation` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/credential-rotation.md` |
| `workspace-provision` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-provision.md` |
| `workspace-launch` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-launch.md` |
| `domain-purchase` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/domain-purchase.md` |
| `workspace-signup` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-signup.md` |
| `domain-dns` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/domain-dns.md` |
| `website-launch` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/website-launch.md` |
| `chrome-profiles` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/chrome-profiles.md` |
| `workspace-icon` | Steffon | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-icon.md` |
| `Xan Heartbeat` | Xan | `mcritchie-studio/docs/agents/agents/xan/HEARTBEAT.md` |
| `Alex Heartbeat` (legacy alias) | Xan | `mcritchie-studio/docs/agents/agents/xan/HEARTBEAT.md` |
| `grade-events` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/grade-events.md` |
| `share-insights` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/share-insights.md` |
| `full-cycle` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/full-cycle.md` |
| `clean-up` | Xan | `mcritchie-studio/docs/agents/agents/xan/sops/clean-up.md` |
| `Rex Heartbeat` | Rex | `mcritchie-studio/docs/agents/agents/rex/HEARTBEAT.md` |
| `constraint-diagnosis` | Rex | `mcritchie-studio/docs/agents/agents/rex/sops/constraint-diagnosis.md` |
| `content-sprint` | Rex | `mcritchie-studio/docs/agents/agents/rex/sops/content-sprint.md` |
| `address-blocker` | Shared | `mcritchie-studio/docs/agents/modules/address-blocker.md` |
| `building-sop` | Shared | `mcritchie-studio/docs/agents/modules/building-sop.md` |
| `focus-session` | Shared | `mcritchie-studio/docs/agents/modules/focus-session.md` |
| `process-backlog` | Shared | `mcritchie-studio/docs/agents/modules/process-backlog.md` |
| `work-backlog` | Shared | `mcritchie-studio/docs/agents/modules/work-backlog.md` |
| `token-session` | Shared | `mcritchie-studio/docs/agents/modules/token-session.md` |
| `knowledge-capture` | Shared | `mcritchie-studio/docs/agents/modules/knowledge-capture.md` |
| `slack-capture` | Shared | `mcritchie-studio/docs/agents/modules/slack-capture.md` |
| `gmail-capture` | Shared | `mcritchie-studio/docs/agents/modules/gmail-capture.md` |
| `credential-issues` | Shared | `mcritchie-studio/docs/agents/modules/credential-issues.md` |
| `form-fill` | Shared | `mcritchie-studio/docs/agents/modules/form-fill.md` |

## LLM Adapters

Claude Code auto-loads `CLAUDE.md`, a thin adapter: the DevOps gate, then `@AGENTS.md`.
Codex reads `AGENTS.md` natively; do not create a root `CODEX.md`. Detail:
`docs/agents/modules/llm-adapters.md`.
