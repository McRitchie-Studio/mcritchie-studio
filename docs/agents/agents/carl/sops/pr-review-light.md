# PR Review Light

## Status: Active

This is the **light reviewer role SOP** — the focused second read one domain
specialist (Shannon · Jasper · Steffon · Alex) runs when **Carl** (the standing
primary and review OWNER) summons it as the **LIGHT** for a submitted PR.

You are a **domain specialist reviewer**, summoned by Carl as his second set of
eyes. You give a **focused second read through your domain lens** and report your
findings up to Carl. You are **not** the owner: you do **not** run the gates
(`bin/dor-check`, cert/CI — that is Carl's job; don't re-run them), you do **not**
drive the verdict, you do **not** summon anyone, you do **not** move the task
stage, and you do **not** merge, deploy, or publish. Carl collects your read
alongside his deep review and drives the verdict to `reviewed` or `blocked`.

## Scope

One PR / one task. A focused second read only — a sharp second perspective
through your domain, not a re-derivation of Carl's deep review and not a re-run of
the gates. You do not drive the verdict, but **any reviewer can block on a defect**
you spot. This SOP does not select or summon reviewers, run the gates, move the
task stage, merge, deploy QA, ship production, or archive work.

Your read is the task's **G2b Light** gate lane
([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md)):
Carl opened it as he summoned you and closes it from your scout report
(`merge-ready` = passed). You post no gate markers yourself — and you do NOT run
`bin/dor-check` in any role: the gate-zero belongs to Carl.

## Entry

Work from the projects root as your own soul:

```bash
cd /Users/alex/projects
```

Read `/Users/alex/projects/AGENTS.md` and the relevant repo
README / runbook / topic docs for the change surface before reviewing.

## Preconditions

Carl handed you a task slug, its PR (base `accepted`), branch, repos, risk tags,
acceptance criteria, and the checks already reported. If any of that is missing,
note it as a finding — do not guess.

## Procedure

1. **Narrate as your own soul — before any review work:**

   ```bash
   bin/agent-activity start --category Verify --agent <your-soul> --task <task-slug> --reason "light review: <task-slug>"
   ```

2. **Focused second read.** A lighter pass than Carl's, centered on your domain
   and the highest-risk surface. **Do not run the gates** — Carl owns
   `bin/dor-check` and the cert/CI verification; you glance at whether `checks_run`
   looks green, but you do not re-run it:
   - **diff vs. acceptance** — the change matches the task's acceptance criteria.
   - **your domain checklist** — walk your soul's REVIEW CHECKLIST (in your
     `role.md`) against the diff; that is where your focused value is highest.
   - **a focused second perspective** — obvious correctness bugs, risky patterns,
     or missing docs Carl may have missed. Depth and the gates are Carl's job;
     your job is a sharp second set of eyes through your domain.

3. **Classify findings** as blockers, non-blockers, or questions.

4. **Record your scout report on the task** (drop `--dry-run` once the payload
   looks right):

   ```bash
   bin/devops-cycle --record-scout-report <task-slug> --scout-agent <your-soul> \
     --outcome <merge-ready|wait-for-ci|request-changes|conductor-review> \
     --summary "..." --finding "..." --check "..." --dry-run
   ```

   - **merge-ready** — no blockers from your read.
   - **request-changes** — you found a **reachable regression** (correctness /
     security / data-loss / acceptance miss, named with its trigger); Carl will
     `block` it back (a light reviewer's block counts — any reviewer can stop a
     PR). A zap-scale defect is not a request-changes: fix it forward on the PR
     branch ([`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md)
     reviewer seam) or name it for Carl to zap; scope/style/hardening ideas go in
     your findings as notes, not the outcome.
   - **wait-for-ci** — CI is still running; Carl defers and re-queries.
   - **conductor-review** — low confidence (the humility valve); route to a human.

5. **Close the activity with your verdict:**

   ```bash
   bin/agent-activity end --outcome "<verdict>: <one-line reason>"
   ```

6. **Return a concise final message** to Carl summarizing the recorded outcome and
   any blockers. Do not summon another reviewer, do not run the gates, and do not
   move the task stage — that is Carl's, the owner's.

## Exit Seam

Your scout report is recorded and your activity is closed with a verdict. Carl
owns the final move to `reviewed` (merged into `accepted`) or `blocked`.

## Related

- [`pr-review.md`](pr-review.md) — the orchestrator SOP that claims PRs and spawns
  each Carl.
- [`pr-review-primary.md`](pr-review-primary.md) — the deep primary review + owner
  role SOP Carl runs (and who summoned you).
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) —
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md) —
  the G2 Review gate your lane (G2b) records into.
