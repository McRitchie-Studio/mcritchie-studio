# Cross LLM Docs Audit

Date: 2026-06-26
Scope: projects-root agent entrypoints, McRitchie Studio agent docs, DevOps SOPs, bootstrap/recovery docs, generated Claude skills, and local worktree hygiene.
Mode: DevOps-tracked audit. Read-only investigation first; this file is the durable audit artifact.
Task: https://mcritchie.studio/tasks/cross-llm-docs-audit

## Executive Summary

The documentation direction is sound: `mcritchie-studio` is the bootstrap anchor, `/Users/alex/projects/AGENTS.md` is the cross-agent entrypoint, and root `CLAUDE.md` is a thin adapter that imports `AGENTS.md`. App-level Claude files are no longer active truth in the managed repos.

The main risk is not that the docs are too Claude-specific. The main risk is stale duplicated SOP text competing with deterministic tooling. The live code and newer docs have moved to the two-workflow stages (`designed -> building -> submitted -> reviewed -> assembled -> shipped`) and an operator-gated production ship, while several active docs and one Claude skill still describe legacy stages or an auto-ship conductor path.

The strongest deterministic pieces already exist: `bin/task`, `bin/dor-check`, `bin/full-suite-check`, `bin/conductor`, `bin/release`, `bin/install-agent-docs`, and `bin/agent-worktree`. The next cleanup should make those tools the visible source of truth and shrink prose that restates their behavior.

## Verified Current State

- Root generated docs are installed and match tracked sources: `bin/install-agent-docs check` reported `/Users/alex/projects/AGENTS.md` and `/Users/alex/projects/CLAUDE.md` both match `docs/agents/{index,claude}.md`.
- Root `CLAUDE.md` is thin and platform-adapter shaped: it contains a short DevOps gate and `@AGENTS.md`, not duplicated app facts.
- Active app docs mostly point to `AGENTS.md` or neutral topic docs. A cross-repo search found no active app-level `CLAUDE.md` entrypoint in the managed repos.
- The task model and `bin/task` use the new stage set: `designed`, `building`, `submitted`, `reviewed`, `assembled`, `shipped`, `blocked`, `archived`.
- `bin/dor-check` is already deterministic and correctly exempts true non-code chores while gating chores that ship code.
- Fresh-machine recovery is mostly deterministic through `bin/ecosystem-build`, which installs root `AGENTS.md`, root `CLAUDE.md`, and user-global Claude skills.
- Local hygiene is not clean: `bin/agent-worktree cleanup` found seven safe cleanup candidates, `bin/agent-worktree doctor` found 32 issues when run with Ruby 3.3, and one unmanaged clean worktree exists at `/Users/alex/projects/mcritchie-studio-ai-builder-cache`.
- `bin/task stale` found zero tasks whose work appears shipped on main but still open.

## Findings

### F1 - High - Ship Policy Contradiction

`docs/agents/system/devops-cycle-design.md` states production ship is always operator-gated, then later says the `Build and Deploy QA Release` SOP auto-ships to production with no human gate. The implementation backs the operator-gated interpretation: `bin/conductor ship` refuses, and the `/stages` helper copy says the operator gate is at ship.

Evidence:

- `docs/agents/system/devops-cycle-design.md` lines 336-337: production ship is always operator-gated.
- `docs/agents/system/devops-cycle-design.md` lines 356-368 and 426-433: the QA release SOP auto-ships with no human gate.
- `docs/agents/skills/qa-release/SKILL.md` lines 2-3 and 20-24 repeat the auto-ship behavior.
- `bin/conductor` lines 43-52 and 400-407 refuses production ship.
- `app/helpers/application_helper.rb` lines 194-198 and 253-259 describe stopping for the prod ship/operator gate.

Recommendation: make one policy canonical. Based on code and most current role docs, treat production as operator-gated and rewrite the `Build and Deploy QA Release` SOP plus `qa-release` skill to stop after QA unless Mr. McRitchie explicitly chooses auto-ship for that session.

### F2 - High - Stage Names Are Split Across Eras

The live task model and CLI use `designed/building/submitted/reviewed/assembled/shipped`, but active docs still instruct agents to move tasks to `in_progress`, `pr_review`, `qa_review`, `prod_ready`, and `done`.

Evidence:

- `app/models/task.rb` lines 34-61 define the live two-workflow stage model.
- `bin/task` lines 242 and 667 enforce the new stage set.
- `docs/agents/modules/devops-task-board.md` lines 73-90 and 190-205 still use legacy stages.
- `docs/agents/modules/worktrees.md` lines 44 and 51-54 tell agents to move to `in_progress` and `pr_review`.
- `/Users/alex/projects/AGENTS.md` lines 267-271 still says to move task to `pr_review`.
- `config/feature_shapes.yml` lines 3-10 still comments in terms of `pr_review`.

Recommendation: collapse the legacy-stage prose into a short compatibility note and make every active instruction use live stages. Add old-stage suggestions to `bin/task` errors if useful, e.g. `pr_review -> submitted`, `in_progress -> building`.

### F3 - Medium - Adapter Policy Has Internal Drift

The adapter policy module correctly says root `CLAUDE.md` is required for Claude Code, but its smoke-test success criteria and generated `AGENTS.md` still say not to create root `CLAUDE.md` by default.

Evidence:

- `docs/agents/modules/llm-adapters.md` lines 7-15 and 26-29 say root `CLAUDE.md` is required.
- The same file lines 43-55 still says success means root `CLAUDE.md` should not be created and suggests adding it only if the test fails.
- `/Users/alex/projects/AGENTS.md` lines 328-330 says not to create root `CLAUDE.md` by default, despite the generated root `CLAUDE.md` existing and matching source.

Recommendation: update policy to: `AGENTS.md` is canonical, root `CLAUDE.md` is a required thin adapter for Claude Code, root `CODEX.md` is not used unless a future platform requires it, app-level LLM files stay non-canonical.

### F4 - Medium - Generated Root Link Is Broken

The generated root `AGENTS.md` contains a relative link to `modules/worktrees.md`, but from `/Users/alex/projects/AGENTS.md` that path does not exist. The canonical file is `mcritchie-studio/docs/agents/modules/worktrees.md`.

Evidence:

- `/Users/alex/projects/AGENTS.md` line 315 links to `modules/worktrees.md`.
- `/Users/alex/projects/modules/worktrees.md` does not exist.
- `/Users/alex/projects/mcritchie-studio/docs/agents/modules/worktrees.md` does exist.

Recommendation: generated root docs should use paths valid from `/Users/alex/projects`, or use plain literal paths instead of Markdown links when the source file is copied into a different directory.

### F5 - Medium - Fresh-Machine Skill Drift Is Detectable But Present

`bin/install-agent-docs check` reported the root docs and `qa-release` skill are current, but local `~/.claude/skills/wrap/SKILL.md` is out of date with `docs/agents/skills/wrap/SKILL.md`.

Recommendation: run `bin/install-agent-docs` as a cleanup action. Also consider making the closeout path run `bin/install-agent-docs check` and surface the exact install command when any generated skill drifts.

### F6 - Medium - Worktree Doctor Needs Ruby Bootstrap

Running `bin/agent-worktree doctor` from the non-interactive shell used system Ruby 2.6.10 and failed on `Array#filter_map`. Running it with the documented Ruby 3.3 path succeeded and reported the actual lifecycle issues.

Evidence:

- Default `ruby --version`: `ruby 2.6.10`.
- Pinned path `ruby --version`: `ruby 3.3.11`.
- `bin/agent-worktree doctor` failed with `undefined method filter_map`.
- `/usr/bin/env PATH=/opt/homebrew/opt/ruby@3.3/bin:... bin/agent-worktree doctor` succeeded.

Recommendation: add a deterministic Ruby bootstrap or version guard to agent-facing Ruby scripts, especially `bin/agent-worktree`, so agents do not have to remember PATH mechanics.

### F7 - Medium - Worktree Registry Needs Cleanup

Local worktree state will make the next session noisier than necessary.

Evidence from `bin/agent-worktree cleanup`:

- Cleanup candidates: `autocommit-release-artifacts`, `close-handoff-label-gap`, `commit-backlogged-retros`, `live-animate-release-deploy`, `prune-cached-commit-observations`, `timeline-sizing-strip`, and Turf Monster `buy-usdc-account-buttons`.

Evidence from `bin/agent-worktree doctor`:

- 32 lifecycle issues total.
- Two dirty merged worktrees: `deployments-live-updates` and `deployments-turbo-streams`.
- `deployments-turbo-streams` is serving on port 3025 but `/up` returns 500.
- Several clean unmerged branches are behind `origin/release`.
- Orphan git worktree: `/Users/alex/projects/mcritchie-studio-ai-builder-cache`, branch `feat/ai-builder-cache-run`, clean but unmanaged.

Recommendation: run the cleanup lane separately. Do not remove dirty or unmerged worktrees blindly. For safe candidates, use the existing approval-gated `bin/agent-worktree cleanup --reclaim --yes` path after Mr. McRitchie approves cleanup.

### F8 - Low - `ecosystem-build.md` Has Stray Markup

`docs/agents/system/ecosystem-build.md` ends with `</content>` and `</invoke>`, which look like copied tool markup rather than documentation.

Evidence:

- `docs/agents/system/ecosystem-build.md` lines 139-140.

Recommendation: remove the stray tags during the next docs cleanup.

### F9 - Low - Claude Skills Are Still Named As Claude-Only

`docs/agents/skills/README.md` accurately describes Claude Code user-global skills. That is fine for the current platform, but the `wrap` and `qa-release` content contains useful model-neutral runbook logic.

Recommendation: keep Claude skills as adapters, but move durable behavior into neutral modules or deterministic scripts. The skills should invoke or point to neutral docs and avoid carrying canonical policy.

## Deterministic-Code Opportunities

1. Add a stage alias/hint table in `bin/task` so old stage names fail with precise replacements.
2. Add `bin/devops-doctor` or extend `bin/conductor plan` to summarize adapter drift, generated-doc drift, stale tasks, cleanup candidates, and Ruby bootstrap health in one deterministic report.
3. Add Ruby version guards to Ruby `bin/` entrypoints that require Ruby 3.3 behavior.
4. Either create the documented `config/release_builder.yml` policy file or remove references to it until the feature lands. The docs currently describe it as the tunable release-autonomy source, but the file is absent.
5. Convert the Claude behavioral smoke test into a scriptable check where possible: verify root `CLAUDE.md` exists, contains `@AGENTS.md`, and `AGENTS.md` contains the DevOps gate.
6. Make `bin/install-agent-docs check` part of the wrap/closeout deterministic checklist for docs and skill changes.
7. Add a generated-root link checker that runs after `bin/install-agent-docs` and validates copied Markdown links from their installed location.

## Recommended Work

1. **Docs Gate Cleanup**: fix the ship-gate contradiction, stage-name drift, adapter policy drift, broken generated-root link, and stray ecosystem-build markup.
2. **Skill Sync Cleanup**: run `bin/install-agent-docs`, then update the `qa-release` skill to match the chosen ship policy.
3. **Tooling Guard Cleanup**: add Ruby bootstrap/version guards and old-stage hints.
4. **Worktree Hygiene Cleanup**: ledger and reclaim safe merged worktrees; separately triage dirty merged and clean unmerged worktrees.
5. **Release Autonomy Cleanup**: either land `config/release_builder.yml` with tests or remove the spec-only references from current SOPs.

## Residual Risk

- This audit did not modify the release policy itself. Until F1 is fixed, agents following the `qa-release` skill may try to run a no-human-confirm production ship even though conductor tooling refuses that path.
- This audit did not delete or reclaim any worktrees. The next session will still see the existing cleanup candidates and dirty stacks.
- The primary `mcritchie-studio` checkout was already dirty before this audit. This audit was done in an isolated worktree and did not touch those primary changes.

## Follow-Up Ledger

- Task to create: `Docs Gate Cleanup`, kind `chore`, risk `docs,deploy`, shape absent unless code changes.
- Task to create: `Tooling Guard Cleanup`, kind `chore`, risk `docs,deploy`, shape `backend`.
- Task to create: `Worktree Hygiene Cleanup`, kind `cleanup`, risk `docs`, no code shape unless lifecycle code changes.
- Task to create: `Release Autonomy Cleanup`, kind `chore`, risk `deploy`, shape `backend` if adding `config/release_builder.yml`.

## Commands Run

- `bin/task create/update/move/show cross-llm-docs-audit`
- `bin/install-agent-docs check`
- `bin/agent-worktree list`
- `bin/agent-worktree doctor` (failed under Ruby 2.6, succeeded under Ruby 3.3 path)
- `bin/agent-worktree cleanup`
- `bin/task stale`
- `git status --short --branch` across managed repos
- Targeted `rg`, `sed`, and `nl` reads for agent docs, DevOps SOPs, task tooling, release tooling, and bootstrap docs
