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
- Worktrees are desks; primary checkouts are loading docks. If you will edit
  code or app docs, create or enter an isolated worktree with an allocated port
  before making changes unless Mr. McRitchie explicitly assigns you as the
  deploy owner for that repo.
- A pushed feature branch preserves code. `main` is for reviewed integration,
  not backup. Feature agents push their own branch and graduate through PR/QA;
  Avi or the designated release conductor merges.

## Default Operating Context

Assume Mr. McRitchie starts agent sessions from `/Users/alex/projects`, and
that a plain feature request should be enough context to begin. The default
launch flow is:

1. Read this file, then `mcritchie-studio/docs/ECOSYSTEM.md`.
2. Identify the target repo and read its README/RUNBOOK/topic docs relevant to
   the request.
3. Pull/check `main` and inspect git status before editing.
4. If the task will change code or active docs, allocate an isolated worktree
   from McRitchie Studio and work there. Keep the primary checkout stable for
   integration, review, and deploys.
5. Use the managed port ranges: McRitchie Studio `3000-3099`, Turf Monster
   `3100-3199`, Tax Studio reserved at `3200-3299`, next app `3300-3399`.
6. Build the feature, run the meaningful tests/checks, and give Mr. McRitchie a
   local URL to react to.
7. If behavior, workflow, env vars, ports, auth, email, deploys, or agent
   operations change, update the owning active docs in the same pass.
8. Commit and push the feature branch when the work is coherent, then run
   `bin/agent-worktree finish <app> <task-slug>` to prepare PR/QA handoff.
   Deploy or merge only when Mr. McRitchie assigned that lane or the task
   explicitly includes production rollout.

For a new feature session, Mr. McRitchie should only need to say the target app
and the feature. A good prompt is:

```text
Work from /Users/alex/projects. Build this feature in <app>: <feature>.
Use an isolated worktree and allocated port before editing. Give me a local URL
to review, update docs if behavior changes, then commit, push the feature
branch, run bin/agent-worktree finish, and prepare a PR for Avi QA. Do not merge
or deploy unless I explicitly assigned that lane.
```

## Start Here

| Need | Read |
|------|------|
| Ecosystem map | `mcritchie-studio/docs/ECOSYSTEM.md` |
| Fresh-machine rebuild | `mcritchie-studio/docs/agents/system/house-burn-down.md` |
| Agent culture | `mcritchie-studio/docs/agents/modules/culture.md` |
| Credentials and 1Password | `mcritchie-studio/docs/agents/modules/credentials.md` |
| Credential item names | `mcritchie-studio/docs/agents/modules/credential-inventory.md` |
| Shared email operations | `mcritchie-studio/docs/agents/modules/email-operations.md` |
| Managed app registry | `mcritchie-studio/docs/agents/modules/app-registry.md` |
| Ports, servers, callbacks | `mcritchie-studio/docs/agents/modules/ports-and-processes.md` |
| Parallel DevOps and QA graduation | `mcritchie-studio/docs/agents/modules/parallel-agent-devops.md` |
| Parallel agents and worktrees | `mcritchie-studio/docs/agents/modules/worktrees.md` |
| LLM adapter policy | `mcritchie-studio/docs/agents/modules/llm-adapters.md` |
| Backend discipline | `mcritchie-studio/docs/agents/modules/backend-discipline.md` |
| Tests | `mcritchie-studio/docs/agents/modules/testing.md` |
| Deploys | `mcritchie-studio/docs/agents/modules/deployment.md` |
| Keeping docs clean | `mcritchie-studio/docs/agents/modules/docs-maintenance.md` |
| Audit playbook | `mcritchie-studio/docs/agents/modules/audit-playbook.md` |
| Shared SES production proof | `mcritchie-studio/docs/agents/audits/ses-production-proof-2026-06-14.md` |
| Fresh final audit | `mcritchie-studio/docs/agents/audits/fresh-final-audit-2026-06-15.md` |
| Final ecosystem closeout | `mcritchie-studio/docs/agents/audits/final-closeout-2026-06-14.md` |
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

For feature work, active-doc edits, or any task that might be committed, start
from McRitchie Studio and allocate a worktree:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree plan turf-monster task-slug
bin/agent-worktree new turf-monster task-slug
bin/agent-worktree up turf-monster task-slug
bin/agent-worktree finish turf-monster task-slug
```

Return the printed `http://localhost:<port>` URL in the handoff.

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
ready for Avi review. Keep the worktree and branch until Avi confirms the PR was
merged or intentionally abandoned.

QA servers, once provisioned, are operated with `mcritchie-studio/bin/qa-server`.
They are release-candidate targets for Mr. McRitchie review before production;
production deploy remains separately approval-gated.

Before reusing or deleting worktrees, inspect lifecycle state:

```bash
bin/agent-worktree list
bin/agent-worktree doctor
bin/agent-worktree cleanup
```

`cleanup` is dry-run only; `cleanup --write` only appends candidates to the delete-later ledger. Actual removal stays manual and approval-gated.

## LLM Adapters

Do not create root `CLAUDE.md` or `CODEX.md` by default. Codex reads `AGENTS.md` natively. Claude compatibility should be tested with this generated `AGENTS.md` first; add a thin adapter only if a future Claude session proves it is needed. See `mcritchie-studio/docs/agents/modules/llm-adapters.md`.
