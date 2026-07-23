# Avi Heartbeat

## Status: Active

This is Avi's heartbeat launcher. It sets Avi's session attribution and routes to
two independent act SOPs:

- [`qa-release`](sops/qa-release.md) - the self-healing sweep: merge the reviewed
  queue onto `release`, pre-QA gate, deploy QA, flip members `assembled` on
  QA-green.
- [`deploy-with-task`](sops/deploy-with-task.md) - expedite ONE named task to
  production behind the clean-release guard (interactive: it asks "What task?").

Use this file when Mr. McRitchie invokes `Avi Heartbeat`. When he invokes a
single Avi act directly, read that act's SOP file.

## Scope

Avi owns the middle of the release pipeline — assembly + QA:

- Sweep reviewed work onto the persistent `release` branch (ONE `accepted →
  release` batch PR per repo).
- Run the pre-QA gate, deploy QA, and flip members to `assembled` on QA-green.
- Stop at the Avi → Steffon seam: the release is live on QA and ready for
  Steffon's `production-deploy` act.

Do not ship production from Avi's heartbeat. Stages 4-5 belong to Steffon's
`production-deploy`, or to Alex's `full-cycle` only when Mr. McRitchie launched
that ship-authorized act. Review is Carl's — do not run `pr-review` or merge feat
PRs from Avi's heartbeat.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat avi
```

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The heartbeat command makes activities self-attribute to Avi unless a delegated
agent explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

Keep attribution here. The act SOP files below are standalone procedures and do
not run `bin/agent-activity heartbeat avi` themselves.

## Act SOPs

Run Avi's heartbeat as a QA-release sitting:

1. [`qa-release`](sops/qa-release.md) - sweep the reviewed queue through release
   assembly and QA (stages 1-3), stopping at Live on QA.

When Mr. McRitchie launches `Avi Heartbeat`, run `qa-release` until the reviewed
queue is swept and the candidate is on QA. When an act is invoked directly, run
only that act.

[`deploy-with-task`](sops/deploy-with-task.md) runs only when invoked directly —
it is a single-task production expedite, never part of the heartbeat
composition.

## Legacy Aliases

The old launcher name still refers to the same work:

- `qa-deploy` -> [`qa-release`](sops/qa-release.md)

## Handoff

End every Avi heartbeat with a short report:

- QA deploy result, or "nothing to prepare"
- release slug, QA URL, and member task list when a candidate moved
- any ejected task and the failing evidence
- confirmation that the release is handed to Steffon only after it is deployed to
  QA

On a clean run with no ejections or blockers, omit the blocker section entirely.

## Background — not needed to execute

This heartbeat is a recipe: it routes to the act SOPs above, and each act stands
alone. These references are context only.

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
  §1.4 - release atom model and pipeline ownership (architecture).
