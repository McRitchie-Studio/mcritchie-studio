# Autonomous Release SOP Audit

Date: 2026-06-27
Task: https://mcritchie.studio/tasks/autonomous-release-sop
Branch audited: `origin/feat/devops-sop-infographic`
Current implementation base: `origin/release` at `c7ba5e5`

## Summary

The SOP direction is sound: keep `Build and Deploy QA Release` as the QA-only
release conductor flow, then add `Merge, Assemble, Deploy` as the explicit
production-authorized sibling. Both workflows should share review, merge,
assemble, QA deploy, straggler review, and ship-readiness. They differ only at
the final ship decision.

## Branch Audit

- `origin/feat/devops-sop-infographic` contains one commit:
  `338ab6d Reword Main Branch node as the merge-forward guard (not a divergence)`.
- That branch is stale relative to `origin/release`; a direct two-dot diff shows
  it would revert newer review-lane work across app code, tests, and agent docs.
- The intended infographic correction already exists on `origin/release`:
  `config/devops_vocabulary.yml` describes Assemble's `Main Branch` node as a
  merge-forward guard, with no divergence marker.
- Do not merge `feat/devops-sop-infographic` wholesale. Treat it as an already
  superseded draft branch.

## Event Tree Alignment

- Builder owns Build through `submitted`.
- Primary Reviewer owns Review, including deep review, spawning LIGHT, moving to
  `reviewed`, and running `bin/release merge`.
- Steffon owns Assemble: merge-forward guard, QA deploy, QA acceptance, then
  `assembled`.
- Avi owns Ship: frozen-SHA tests, visual/product acceptance, production deploy,
  `shipped`, and smoke seal.
- The diagram's `Main Branch` node must remain a merge-forward guard: release
  keeps main as an ancestor; main itself advances only during ship.

## SOP Decision

- `Build and Deploy QA Release` remains intact and stops before production.
- `Merge, Assemble, Deploy` is the new autonomous production workflow.
- Both workflows invoke the same shared conductor phases and share the same
  hard gates. The autonomous workflow only changes who answers the production
  confirm: it runs `bin/conductor ship --run`, which delegates to
  `bin/release ship --by conductor --yes`.
- `--yes` skips only the human confirm. It does not bypass clean-main preflight,
  frozen-SHA tests, producer-first gem publish, deployment smoke,
  `post_deploy_cmd`, or partial-ship recovery.

## Follow-Up Watchpoints

- Keep `config/devops_vocabulary.yml`, `/stages/sop`, and
  `docs/agents/system/devops-cycle-design.md` synchronized.
- Treat the exact phrase `Merge, Assemble, Deploy` as production authority; do
  not infer production authority from "prepare QA" or
  `Build and Deploy QA Release`.
- When this branch merges, run `bin/install-agent-docs install` from the primary
  checkout so root agent docs and global Claude/Codex skills receive the updated
  launcher wording.
