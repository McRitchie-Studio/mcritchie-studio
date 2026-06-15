# Parallel Agent DevOps

This is the operating model for many agents working at once without losing
code. It separates backup, review, integration, and release into different
lanes.

## Core Idea

`main` is not the backup location. A pushed feature branch is the backup
location.

Feature agents should feel free to move quickly inside isolated worktrees, but
they do not merge to `main`. Work graduates through a PR review lane where Avi
protects integration, Steffon adds QA/deploy scrutiny when needed, and the
release conductor handles production effects.

## Lanes

| Lane | Owner | Purpose | May push branch | May merge main | May deploy/publish |
|------|-------|---------|-----------------|----------------|--------------------|
| Feature | Task agent | Build scoped work in an isolated worktree | Yes, own branch only | No | No |
| QA / Integration | Avi | Review PRs, prevent dropped code, merge approved work | Yes, review/fix branches when needed | Yes | No, unless explicitly acting as release conductor |
| Quality / Infra Gate | Steffon | Validate risky PRs, CI, deploy readiness, provider infra | Yes, review/fix branches when needed | No, unless delegated by Avi | No, unless release conductor |
| Release | Designated conductor | Gem publish, app deploy, production verification | Yes | Yes | Yes, with explicit approval |

One session can wear multiple hats only when Mr. McRitchie explicitly says so.
Default feature sessions are Feature lane only.

## Feature Branch Lifecycle

1. **Start** from `/Users/alex/projects`.
2. **Read** root `AGENTS.md`, then the relevant app docs.
3. **Allocate** a task worktree from McRitchie Studio:

   ```bash
   cd /Users/alex/projects/mcritchie-studio
   bin/agent-worktree plan <app> <task-slug>
   bin/agent-worktree new <app> <task-slug>
   ```

4. **Build** only inside `/Users/alex/projects/<repo>/.worktrees/<task-slug>`.
5. **Run** meaningful checks and start the stack when visual/local proof matters:

   ```bash
   bin/agent-worktree up <app> <task-slug>
   ```

6. **Commit** coherent work on the feature branch.
7. **Graduate** through the launcher:

   ```bash
   bin/agent-worktree finish <app> <task-slug>
   bin/agent-worktree finish <app> <task-slug> --push
   bin/agent-worktree finish <app> <task-slug> --push --pr
   ```

8. **Handoff** the PR/QA packet. Do not merge to `main` unless assigned the QA
   or Release lane.

## Feature Graduation Rules

Before a branch is ready for QA, it must be:

- in a generated worktree, not the primary checkout
- on a feature branch, not `main`
- committed cleanly
- ahead of `origin/main`
- rebased when `origin/main` has moved
- pushed to GitHub before the worktree is considered safe to clean up
- accompanied by a local proof URL or a clear explanation of why no URL applies

`bin/agent-worktree finish` enforces the obvious checks and prints the PR body.
It blocks dirty worktrees, branches with no commits, branches already merged to
`origin/main`, and branches behind `origin/main`.

## QA / Avi Review

Avi owns PR intake and merge safety.

For each PR, Avi checks:

- the PR body matches the diff
- the branch started from current enough `main`
- the local proof URL or test evidence is credible
- the work does not silently overwrite another agent's changes
- docs changed when behavior, env, ports, auth, email, deploys, or workflow changed
- the branch should merge now, wait for another PR, or be sent back

Avi should avoid rewriting feature branches unless taking explicit ownership of
the fix. If Avi does modify a PR, the PR comment must say what changed and why.

## Steffon QA Gate

Steffon gates PRs with operational risk:

- migrations or data backfills
- payment, email, auth, Solana, wallet, SSO, or provider changes
- deploy/buildpack/env-var changes
- production incident fixes
- UI flows where browser proof is the core acceptance criterion

Low-risk docs or copy PRs can merge with Avi review alone. When in doubt, Avi
asks Steffon for QA before merge.

## Release Conductor

Publishing gems, updating app lockfiles after a gem release, deploying apps, and
changing provider configuration are Release-lane actions.

Rules:

- Only one conductor owns a release train at a time.
- The conductor pulls latest `main` in every affected repo before release work.
- Engine changes use their own release train: source commit, version bump,
  release check, gem publish, consumer lockfile updates, app verification.
- Deploys require explicit approval from Mr. McRitchie unless the prompt already
  included production rollout.
- The conductor reports production URLs and verification results before cleanup.

## Code Loss Prevention

- A pushed feature branch preserves work. Merging to `main` is an integration
  decision, not a backup step.
- Never delete a feature branch or worktree until the PR is merged or explicitly
  abandoned.
- `cleanup` only records candidates in the delete-later ledger; removal remains
  approval-gated.
- Feature agents do not force-push shared branches. If a rebase needs a push,
  use `--force-with-lease` only on your own branch.
- If another agent moved `origin/main`, rebase and rerun checks before PR.
- If another agent changed the same files, let Git surface the conflict. Do not
  manually recreate or overwrite their work from memory.

## 100-Agent Scaling Notes

The current slot allocator uses app port ranges and `.env.agent-stack` files as
the local session registry. That is enough for dozens of occasional worktrees.

Known future ceilings:

- Stock Redis usually exposes DBs `0-15`; many live stacks need more Redis DBs
  or dedicated Redis instances.
- Browser-heavy flows on 100 ports will be CPU-bound before Git becomes the
  problem.
- Shared dependency release trains, especially `studio-engine`, need a single
  conductor and should not be merged casually by feature agents.
- Callback-heavy provider flows should stay on primary ports unless each
  provider is configured for worktree callback URLs.

When the current `.env.agent-stack` registry becomes too small, promote it into
a durable machine-readable registry under `/Users/alex/projects/.agents/`.

## Recurring Feature Prompt

Use this prompt for ordinary future feature sessions:

```text
Work from /Users/alex/projects. Build this feature in <app>: <feature>.

Use the parallel-agent protocol:
- create or enter an isolated worktree with bin/agent-worktree
- use the allocated port and give me the local URL
- keep all edits inside the task worktree
- update docs if behavior, workflow, env, ports, auth, email, or deploys change
- commit your work on the feature branch
- run bin/agent-worktree finish before handoff
- push the branch and open/prepare a PR for Avi QA

Do not merge to main, publish gems, deploy, force-push, delete branches, or
delete worktrees unless I explicitly approve that lane for this session.
```
