# Session Retrospective - 2026-06-17

## Scope

Retrospective for the multi-day agent cleanup and audit session that reset the
McRitchie projects around neutral agent docs, shared email/auth infrastructure,
worktree isolation, QA intake, Studio Engine release flow, and Turf Monster PR
cleanup.

This file is not a replacement for the current operational closeout in
[`final-closeout-2026-06-17.md`](final-closeout-2026-06-17.md). It records the
frictions and durable lessons future agents should inherit.

## What Worked

- The root `AGENTS.md` model worked. A neutral, generated projects-root entry
  point gave Codex a stable first file without requiring `CLAUDE.md` or
  `CODEX.md` adapters.
- Keeping McRitchie Studio as the documentation source of truth worked. Durable
  agent docs, recovery docs, QA tooling, and cleanup ledgers now live in GitHub
  instead of machine-local memory.
- The worktree model worked. Isolated worktrees plus app port ranges let
  multiple agents move at once without dirtying primary checkouts.
- QA intake became the right conductor view. It joined open PRs, local worktree
  state, merge risk, health, and cleanup candidates into one owner-facing queue.
- The shared Studio Engine path paid off. Email, auth, non-production banners,
  and common UI primitives moved toward one engine instead of drifting per app.
- Local-first email capture reduced friction. Magic links and auth flows were
  testable from `/_studio/local_emails` without asking Mr. McRitchie to operate
  Gmail or provider dashboards for ordinary local work.

## Frictions

- Squash merges confuse naive branch lifecycle checks. A feature branch can look
  behind `origin/main` after its PR lands as a squash commit, even when the
  branch diff is fully represented on `main`. Before deleting, compare the final
  branch to `origin/main`; if the diff is empty, cleanup is safe after stopping
  the stack and ledgering the removal.
- Registry drift is real. Removing an orphaned `.worktrees/<task>` directory is
  not enough if `/Users/alex/projects/.agents/worktree-registry.json` still
  references it. Refresh the registry with `bin/agent-worktree snapshot --write`
  and rerun `bin/qa-intake`.
- CI latency is not the same as a code failure. One Playwright shard spent a
  long time installing/running while the other jobs were green. Watch the run,
  inspect logs only when available, and avoid branch churn while GitHub is still
  progressing.
- `missing-local-branch` does not always mean "fix it here." It can mean another
  agent owns the branch. The conductor should not recreate or modify that PR
  unless assigned the lane.
- Local tool permissions matter. Some useful writes, such as refreshing the
  machine registry or deleting stale directories, need explicit approval. Ask
  for the smallest exact approval instead of asking Mr. McRitchie to run a
  terminal command.
- Provider/DNS work is external-state heavy. SES production access and DNS/ACM
  propagation needed patience, screenshots, and exact records. Agents should
  separate local implementation completion from external-provider waiting.

## Durable Rules Added Or Reinforced

- Primary checkouts are for reading, pulling, integration, and deployment.
  Feature work belongs in generated task worktrees.
- A pushed feature branch preserves work. `main` is reviewed integration, not
  a panic backup.
- QA and Release are separate lanes. QA can merge/deploy to QA when assigned;
  production rollout, gem publish, provider changes, and destructive cleanup
  require explicit approval.
- Cleanup is ledgered, verified, and then removed. Do not delete worktrees just
  because they look old.
- Future agents should hand Mr. McRitchie something inspectable: URL, inbox URL,
  screenshot, passing check summary, commit SHA, or an explicit blocker.

## Recommended Future Improvements

- Add CI-watch guidance or tooling for long-running GitHub Actions jobs so
  agents can distinguish "runner still progressing" from "test failure needs
  artifacts."
- Consider a future dashboard over `/Users/alex/projects/.agents/worktree-registry.json`
  once agent concurrency grows beyond what a terminal queue can comfortably
  express. The registry now includes squash-merge-aware cleanup candidates and
  the launcher has an approval-gated removal path.
