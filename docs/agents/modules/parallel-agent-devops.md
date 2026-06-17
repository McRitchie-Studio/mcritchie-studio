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

Start conductor sessions by generating the PR/worktree queue from McRitchie
Studio:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster
```

`bin/qa-intake` refreshes
`/Users/alex/projects/.agents/worktree-registry.json`, joins the local worktree
state with open GitHub PRs, and prints an Avi-ready queue. Add apps to
`--apps` as new satellites are promoted. Use `--json` when a supervisor script
or dashboard should consume the same queue. Every printed queue item includes an
`action:` line. Treat that action as the next owner handoff unless new evidence
from the diff, tests, or Mr. McRitchie changes the call.

Status labels mean:

- `avi-ready`: clean local branch with a matching PR, no blocking local issues,
  and no merge/check warnings.
- `avi-ready-draft`: clean local branch and clean merge state, but the PR is
  still draft.
- `checks-review`: local branch is present, but GitHub reports unstable checks;
  inspect CI before merge.
- `merge-risk`: GitHub reports conflict, blocked, dirty, or unknown merge
  state.
- `needs-agent`: the local branch has blocking worktree issues such as a dirty
  tree, stale branch, broken `/up`, missing stack env, or Redis slot problem.
- `missing-local-branch`: GitHub has an open PR, but the current machine has no
  matching local worktree.
- `ready-to-open-pr`: local branch has no matching open PR and is clean,
  current with `origin/main`, and ready for `bin/agent-worktree finish`.

Action lines mean:

- `Avi can review...`: review diff, evidence, overlap, then merge or comment.
- `return to the feature agent...`: do not merge; the branch owner needs to
  resolve local blockers.
- `rebase or repair...`: merge state is unsafe; fix branch freshness/conflicts
  before QA.
- `inspect checks...`: wait for CI/checks or make an explicit conductor
  decision.
- `recreate a local worktree...`: the machine cannot inspect the branch safely;
  fetch/recreate it or ask the branch owner for a handoff.
- `open a draft PR...`: run the printed finish command from the worktree owner
  lane, then let Avi review.

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

## QA Deployment

QA deployment sits between PR merge and production deploy.

The intended cycle is:

1. Feature agent opens a PR.
2. Avi reviews and merges when ready.
3. Avi or Steffon provisions the QA app once if `bin/qa-server status <app>`
   reports `missing-app`.
4. Avi or Steffon deploys the merged `main` ref to the app's QA server with
   `bin/qa-server deploy <app> origin/main --yes`.
5. Mr. McRitchie reviews the QA URL.
6. Production deploy happens only after Mr. McRitchie explicitly approves it.

QA servers are tracked in `config/qa_environments.yml` and operated through
`bin/qa-server`. A QA deploy is allowed for the QA conductor lane, but it must
target the QA Heroku app, never the production app. Turf Monster QA must stay on
devnet with `PAYMENT_PROVIDER=none`. The intended stable review URLs are
`https://qa.mcritchie.studio` and `https://qa.turfmonster.media`; use
`bin/qa-server status <app>` to confirm the Heroku app, DNS target, and `/up`
checks before asking Mr. McRitchie to review.

## Recurring QA Intake Prompt

Use this prompt when Mr. McRitchie wants a session to run the PR review, merge,
and QA deployment cycle:

```text
Work from /Users/alex/projects as the QA / Integration lane.

Run the parallel-agent DevOps cycle:
- read /Users/alex/projects/AGENTS.md and the app docs
- pull latest main in mcritchie-studio and each affected app
- run `bin/qa-intake --refresh --apps mcritchie-studio,turf-monster` from
  McRitchie Studio, adding any other app mentioned in the current work
- use the QA intake queue to identify avi-ready, checks-review, merge-risk,
  needs-agent, missing-local-branch, ready-to-open-pr, and cleanup candidates;
  follow each item's `action:` line for the next owner handoff
- review each PR for diff/description match, CI or local proof, docs impact, migrations, auth/email/payment/Solana risk, and overlap with other open PRs
- ask Steffon/infra review for risky changes before merge when needed
- merge only PRs that are ready; leave comments on PRs that need changes
- after merging, deploy the updated origin/main to the relevant QA app with bin/qa-server deploy <app> origin/main --yes
- run bin/qa-server status <app> and report the QA URL, /up status, release SHA, and what Mr. McRitchie should review

Do not deploy production, publish gems, delete worktrees, delete branches, or force-push unless Mr. McRitchie explicitly authorizes that lane in this session.
```

This cycle ends at QA. Mr. McRitchie reviews the QA URL and then gives a
separate production instruction if the release should go live.

## Recurring Production Release Prompt

Use this only after QA has passed and Mr. McRitchie asks for production rollout:

```text
Work from /Users/alex/projects as the Release lane.

Promote the accepted QA work to production:
- read /Users/alex/projects/AGENTS.md and the deployment docs
- pull latest main in mcritchie-studio and each affected app
- confirm the QA deployment SHA and production target app
- run the app-specific deployment command from the repo docs
- verify production /up and the user-facing URL
- report production URL, release SHA/version, checks run, and any follow-up cleanup

Do not include unrelated PRs or new feature work in this rollout.
```

## Code Loss Prevention

- A pushed feature branch preserves work. Merging to `main` is an integration
  decision, not a backup step.
- Never delete a feature branch or worktree until the PR is merged or explicitly
  abandoned.
- Start conductor sessions with `bin/agent-worktree snapshot --write` so the
  current machine queue is captured before branches, pidfiles, or ports move.
- `cleanup` only records candidates in the delete-later ledger; removal remains
  approval-gated.
- Feature agents do not force-push shared branches. If a rebase needs a push,
  use `--force-with-lease` only on your own branch.
- If another agent moved `origin/main`, rebase and rerun checks before PR.
- If another agent changed the same files, let Git surface the conflict. Do not
  manually recreate or overwrite their work from memory.

## 100-Agent Scaling Notes

The current slot allocator uses app port ranges and `.env.agent-stack` files as
the local session registry. `bin/agent-worktree snapshot --write` turns that
state into `/Users/alex/projects/.agents/worktree-registry.json`, a local
machine-readable queue for QA, release, dashboards, and future supervisor
agents. That is enough for dozens of occasional worktrees.

Known future ceilings and controls:

- Stock Redis usually exposes DBs `0-15`. The launcher defaults to worktree
  DBs `9-15` and refuses to allocate beyond that range. Clean merged worktrees
  first, or increase Redis `databases` and set `AGENT_REDIS_MAX_DB=<max>` for an
  intentional high-concurrency window.
- Browser-heavy flows on 100 ports will be CPU-bound before Git becomes the
  problem.
- Shared dependency release trains, especially `studio-engine`, need a single
  conductor and should not be merged casually by feature agents.
- Stable QA servers should absorb release-candidate review so `main` can be
  ahead of production without forcing production deploys.
- Callback-heavy provider flows should stay on primary ports unless each
  provider is configured for worktree callback URLs.

When the current local JSON registry becomes too small, promote it from a
generated snapshot into a lockable service or database-backed coordinator. Do
not skip directly to that complexity until the file-based queue is proving too
small in real use.

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
