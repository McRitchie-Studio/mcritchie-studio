# Git Protocol for Parallel Agent Work

The binding code of version-control ethics for every agent operating in any McRitchie repo. Every `soul.md` references this doc. These rules supersede individual preference.

## Why this exists

When multiple agent instances share a codebase, naïve git workflows produce: branches switching under you mid-edit, files mutating during Edit, stashes drifting from their labels, and merge conflicts masquerading as bugs. We have been bitten by all of these. The rules below are recovery, not theory.

## Worktrees, not shared checkouts

Every implementation task gets its own hidden git worktree -- an independent
working directory sharing the underlying `.git` database. A branch can only be
checked out in one worktree at a time; git enforces this for us.

```
~/projects/<repo>                          # primary checkout, integration/deploy
~/projects/<repo>/.worktrees/<task-slug>   # per-task worktrees
~/projects/turf-monster/.worktrees/new-contest-card
~/projects/mcritchie-studio/.worktrees/parallel-agent-devops
```

Create:
```
cd ~/projects/mcritchie-studio
bin/agent-worktree new <app> <task-slug>
```

Graduate when done:
```
bin/agent-worktree finish <app> <task-slug> --push --pr
```

Remove only after the PR is merged or intentionally abandoned:
```
bin/agent-worktree cleanup --write
bin/agent-worktree remove <app> <task-slug> --yes
```

## Branch naming

Default branch naming is `<type>/<task-slug>`, where type is usually `feat`.
Here `<task-slug>` means the worktree slug recorded on the production task as
`metadata["devops"]["worktree_slug"]`; it is separate from the app's immutable
random `Task.slug`. Do not include an agent id in the branch unless the task
itself requires it.

Examples:
- `feat/agent-page-banner`
- `feat/dark-mode-cards`
- `fix/usdc-vault-refactor`
- `chore/heroku-buildpack-bump`

Feature agents push only their own branch. `main` is not a backup target.

## PR ownership

| Step | Owner | Meaning |
|---|---|---|
| Branch pushed + PR opened | Feature agent | From the task worktree, against `origin/main` |
| PR intake + merge safety | Avi | "This matches the ticket and does not drop another branch's work" |
| QA pass when warranted | Steffon | "Tests green, acceptance criteria met, no regression" |
| Merge | Avi or release conductor | Only after PR review and required QA |
| Release/deploy/gem publish | Release conductor | Only with explicit production/release approval |

Avi can merge low-risk docs/tooling/copy PRs alone. Risky code, migrations,
auth, payments, email, Solana, provider config, or deployment changes get
Steffon QA. Disagreement between Avi and Steffon escalates to Alex the
orchestrator, and to Mr. McRitchie when product or external-account judgment is
needed.

## Send-back format (rejected PR)

When Steffon (or Avi) rejects, the chat message goes in the PR's chat thread using this template:

```
@<author> — Rejected
Reason: <one line>
Acceptance criterion not met: <which>
Evidence: <test failure / screenshot / repro steps>
Look at: <file:line>
Suggested direction: <if obvious> | Open: <if unsure>
```

A rejection is a teaching moment, not a punishment. Be specific about what *would* pass.

## The ethics (binding rules)

1. **Never stash unfamiliar uncommitted changes.** If you open a worktree and find work you didn't create, stop. Log to chat, escalate. Stash labels often lie about contents — never trust them.
2. **Always branch off `origin/main`.** Never off another agent's branch unless coordinated explicitly in chat.
3. **`--force-with-lease`, never `--force`.** `--force` can silently overwrite a colleague's push.
4. **Re-read a file before Edit** when in a shared worktree. Files mutate under you.
5. **Pre-commit hooks always run.** Never `--no-verify`. If a hook fails, investigate. Don't work around.
6. **Your branch is your responsibility.** Never push to another agent's branch.
7. **Rebase, don't merge, when `main` advances.** Before opening a PR, fetch and rebase on `origin/main`. Keep history linear.
8. **One in-flight branch per agent instance.** If you need to start something else, finish or abandon the current branch first.
9. **Do not delete review evidence early.** Keep the branch and worktree until Avi confirms the PR is merged or intentionally abandoned.

## When in doubt

Ask in chat. Git mistakes are recoverable; pushing through ambiguity rarely is.
