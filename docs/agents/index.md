# McRitchie Agent Entry

This is the canonical source for the generated projects-root `AGENTS.md`.
McRitchie Studio owns this file so the agent operating model survives a wiped local machine and can be restored from GitHub.

Paths below are written for the generated file at `/Users/alex/projects/AGENTS.md`.

## First Rules

- Work from `/Users/alex/projects` unless the user gives a different root.
- Treat `mcritchie-studio` as the documentation and bootstrap anchor.
- Keep repo-specific facts in the owning repo, but keep cross-repo operating rules here.
- Do not print secrets. Use named 1Password references and purpose-built scripts.
- Do not hand the user terminal chores. Run safe commands yourself; ask the user for approvals, credentials, product judgment, or external access.
- Prefer a concrete local result the user can inspect: a URL, a diff, a passing command, or a short audit.

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
| Parallel agents and worktrees | `mcritchie-studio/docs/agents/modules/worktrees.md` |
| LLM adapter policy | `mcritchie-studio/docs/agents/modules/llm-adapters.md` |
| Backend discipline | `mcritchie-studio/docs/agents/modules/backend-discipline.md` |
| Tests | `mcritchie-studio/docs/agents/modules/testing.md` |
| Deploys | `mcritchie-studio/docs/agents/modules/deployment.md` |
| Keeping docs clean | `mcritchie-studio/docs/agents/modules/docs-maintenance.md` |
| Shared SES production proof | `mcritchie-studio/docs/agents/audits/ses-production-proof-2026-06-14.md` |
| Final ecosystem closeout | `mcritchie-studio/docs/agents/audits/final-closeout-2026-06-14.md` |
| Latest ecosystem audit | `mcritchie-studio/docs/agents/audits/broader-ecosystem-audit-2026-06-14.md` |
| Delete later ledger | `mcritchie-studio/docs/agents/maintenance/delete-later.md` |

## Repos

| Repo | Role | Local port |
|------|------|------------|
| `mcritchie-studio` | Flagship hub, SSO source, recovery scripts, agent docs | 3000 |
| `turf-monster` | Sports pick'em satellite, payments, Solana integration | 3100 |
| `studio-engine` | Shared Rails engine for auth, theme, error logs, SSO | none |
| `solana-studio` | Ruby Solana primitives | none |
| `turf-vault` | Anchor smart contract | none |

## Session Shape

1. Read this file first.
2. Read only the modules relevant to the task.
3. Check git status before editing.
4. Make scoped changes in the correct repo or worktree.
5. Run meaningful verification yourself.
6. Hand back something inspectable: local URL, screenshot, test output summary, diff summary, or explicit blocker.
7. Update docs when behavior or workflow changes.

## Parallel Work Quick Start

For work that should not touch a primary checkout, start from McRitchie Studio:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree plan turf-monster task-slug
bin/agent-worktree new turf-monster task-slug
bin/agent-worktree up turf-monster task-slug
```

Return the printed `http://localhost:<port>` URL in the handoff.

For email or auth flows, also return the printed local inbox:

```text
http://localhost:<port>/_studio/local_emails
```

Worktree stacks default to `LOCAL_EMAIL_CAPTURE=1`, so magic links and other emails are recorded there instead of sent to real inboxes.

Before reusing or deleting worktrees, inspect lifecycle state:

```bash
bin/agent-worktree list
bin/agent-worktree doctor
bin/agent-worktree cleanup
```

`cleanup` is dry-run only; `cleanup --write` only appends candidates to the delete-later ledger. Actual removal stays manual and approval-gated.

## LLM Adapters

Do not create root `CLAUDE.md` or `CODEX.md` by default. Codex reads `AGENTS.md` natively. Claude compatibility should be tested with this generated `AGENTS.md` first; add a thin adapter only if a future Claude session proves it is needed. See `mcritchie-studio/docs/agents/modules/llm-adapters.md`.
