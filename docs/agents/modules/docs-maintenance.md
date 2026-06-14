# Docs Maintenance

Docs are part of the product surface for agents. When code changes behavior, update the document that a future session would read first.

## Source Of Truth

- Cross-repo agent workflow: `mcritchie-studio/docs/agents/`
- Ecosystem map and recovery: `mcritchie-studio/docs/ECOSYSTEM.md`, `docs/agents/system/house-burn-down.md`
- Shared email operations: `mcritchie-studio/docs/agents/modules/email-operations.md`
- App-specific behavior: the owning repo's README, runbook, and topic docs
- Historical audits and prompts: archive or ledger once their live facts are promoted

## Drift Review

When finishing a meaningful feature:

1. Search docs for the changed route, env var, port, provider, model, or workflow.
2. Update the canonical doc.
3. If an old doc is superseded but not safe to delete yet, add it to [`../maintenance/delete-later.md`](../maintenance/delete-later.md).
4. Prefer deleting stale docs over preserving contradictory context.

## Closeout Checklist

Use this before handing a feature back:

1. Check `git status --short --branch` in every repo you touched.
2. Run the narrowest meaningful tests or smoke checks yourself.
3. Run `bin/install-agent-docs check` from McRitchie Studio if
   `docs/agents/index.md` or generated root guidance changed.
4. Run `bin/register-satellite --list` after app registry changes.
5. Run `bin/agent-worktree doctor` after worktree lifecycle changes.
6. Return an inspectable result: local URL, local inbox URL, screenshot, test
   summary, commit SHA, or concrete blocker.

## Recurring Drift Maintenance

Do this weekly, or after several agent sessions:

1. Review [`../maintenance/delete-later.md`](../maintenance/delete-later.md).
2. Check for visible sibling worktrees and hidden `.worktrees/` salvage dirs.
3. Re-check root stray files under `/Users/alex/projects`.
4. Search for old ports, domains, provider names, and LLM-specific references
   in active docs.
5. Promote durable lessons from local memory or chat into McRitchie Studio docs.

Keep historical audits available when they still explain why a decision was
made, but add an archive banner or ledger row when they could be mistaken for
current procedure.

## Machine-Local Claude Context

Old Claude memory under `/Users/alex/.claude/` can contain useful history, but it is not durable source of truth. Promote durable lessons into `mcritchie-studio/docs/agents/` or the owning repo docs.

Imported lessons from the first cleanup pass:

- Give the user something inspectable, usually a local URL, screenshot, or test result summary.
- Leave documentation cleaner than you found it.
- Use targeted 1Password reads; never print secrets.
- Treat old `3001` and `turf.mcritchie.studio` references as stale unless the file is explicitly historical.
- Route backend failures through `ErrorLog` when the app supports it.
- Validate before irreversible external effects.
- Keep reusable local maintenance scripts in a tracked repo, preferably McRitchie Studio, so a fresh machine can rebuild them.

## Avoid

- Duplicating volatile test counts.
- Encoding secrets directly in docs.
- Adding LLM-specific files when an agent-neutral module will do.
- Leaving old audit prompts next to active runbooks without an archive marker.
