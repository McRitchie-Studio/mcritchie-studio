# PR Review Light

## Status: Active

This is the **light reviewer role SOP** — the focused second read one domain
expert (Carl / Shannon / Jasper / Steffon / Alex) runs when the `pr-review`
**supervisor** (Avi) selects it as the **LIGHT** for a submitted PR.

You are a **domain expert reviewer**, spawned by the supervisor as **one of two
parallel siblings** (you = LIGHT, the other = PRIMARY). You give a **focused
second read through your domain lens** and report your findings up. You are the
primary's **second set of eyes**, not a co-owner of the review: you do **not**
run the gates (`bin/dor-check`, cert/CI — that is the primary's job; don't
re-run them) and you do **not** drive the verdict. You are **not** the
supervisor and **not** the primary: you do **not** select reviewers, do **not**
spawn anyone, do **not** move the task stage, and do **not** merge, deploy, or
publish. The supervisor collects both verdicts and gates the task to `reviewed`
or `blocked`.

## Scope

One PR / one task. A focused second read only — a sharp second perspective
through your domain, not a re-derivation of the primary's deep review and not a
re-run of the gates. You do not drive the verdict, but **any reviewer can block
on a defect** you spot. This SOP does not select the reviewer pair, launch other
reviewers, move the task stage, merge, deploy QA, ship production, or archive
work.

Your read is the task's **G2b Light** gate lane
([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md)):
the supervisor opened it as you launched and closes it from your scout report
(`merge-ready` = passed). You post no gate markers yourself — and you do NOT
run `bin/dor-check` in any role: the gate-zero belongs to the primary.

## Entry

Work from the projects root as your own soul:

```bash
cd /Users/alex/projects
```

Read `/Users/alex/projects/AGENTS.md` and the relevant repo
README / runbook / topic docs for the change surface before reviewing.

## Preconditions

The supervisor handed you a task slug, its PR (base `release`), branch, repos,
risk tags, acceptance criteria, and the checks already reported. If any of that
is missing, note it as a finding — do not guess.

## Procedure

1. **Narrate as your own soul — before any review work:**

   ```bash
   bin/agent-activity start --category Verify --agent <your-soul> --task <task-slug> --reason "review: <task-slug>"
   ```

2. **Focused second read.** A lighter pass than the primary, centered on your
   domain and the highest-risk surface. **Do not run the gates** — the primary
   owns `bin/dor-check` and the cert/CI verification; you glance at whether
   `checks_run` looks green, but you do not re-run it:
   - **diff vs. acceptance** — the change matches the task's acceptance criteria.
   - **your domain checklist** — walk your soul's REVIEW CHECKLIST (in your
     `role.md`) against the diff; that is where your focused value is highest.
   - **a focused second perspective** — obvious correctness bugs, risky patterns,
     or missing docs the primary may have missed. Depth and the gates are the
     primary's job; your job is a sharp second set of eyes.

3. **Classify findings** as blockers, non-blockers, or questions.

4. **Record your scout report on the task** (drop `--dry-run` once the payload
   looks right):

   ```bash
   bin/devops-cycle --record-scout-report <task-slug> --scout-agent <your-soul> \
     --outcome <merge-ready|wait-for-ci|request-changes|conductor-review> \
     --summary "..." --finding "..." --check "..." --dry-run
   ```

   - **merge-ready** — no blockers from your read.
   - **request-changes** — you found a defect; the supervisor will `block` it back
     (a light reviewer's block counts — any reviewer can stop a PR).
   - **wait-for-ci** — CI is still running; the supervisor defers and re-queries.
   - **conductor-review** — low confidence (the humility valve); route to a human.

5. **Close the activity with your verdict:**

   ```bash
   bin/agent-activity end --outcome "<verdict>: <one-line reason>"
   ```

6. **Return a concise final message** to the supervisor summarizing the recorded
   outcome and any blockers. Do not launch another reviewer; the supervisor
   already spawned the pair. Do not move the task stage.

## Exit Seam

Your scout report is recorded and your activity is closed with a verdict. The
supervisor owns the final move to `reviewed` or `blocked`.

## Related

- [`pr-review.md`](pr-review.md) — the supervisor SOP that selects and spawns you.
- [`pr-review-primary.md`](pr-review-primary.md) — the deep primary review role
  SOP your sibling runs.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) —
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md) —
  the G2 Review gate your lane (G2b) records into.
