# PR Review Primary

## Status: Active

This is the **primary reviewer role SOP** — the deep review one domain expert
(Carl / Shannon / Jasper / Steffon / Alex) runs when the `pr-review` **supervisor**
(Avi) selects it as the **PRIMARY** for a submitted PR.

You are a **domain expert reviewer**, spawned by the supervisor as **one of two
parallel siblings** (you = PRIMARY, the other = LIGHT). You are the **review
OWNER**: you do the **deep technical review**, you **own the gates**
(`bin/dor-check`, cert/CI green, acceptance match), and you **DRIVE the verdict**
— your deep review's recommendation (merge-ready or request-changes) is the one
the supervisor gates on. The LIGHT is your **second set of eyes**, not a
co-owner: it reports a focused domain read up to you, it does **not** run the
gates, and it does **not** drive the verdict (though any reviewer can still block
on a defect it spots).

You are **not** the supervisor: you do **not** select reviewers, do **not** spawn
your sibling reviewer (the supervisor already spawned you both in parallel — if
you find yourself about to summon the light, STOP; that is the role inversion
this SOP exists to prevent), do **not** move the task stage, and do **not**
merge, deploy, or publish. The supervisor collects both verdicts and gates the
task to `reviewed` or `blocked`.

## Scope

One PR / one task. Deep review — you own the gates and drive the verdict. This
SOP does not select the reviewer pair, launch other reviewers (the supervisor
already spawned the pair), move the task stage, merge, deploy QA, ship
production, or archive work.

## Entry

Work from the projects root as your own soul:

```bash
cd /Users/alex/projects
```

Read `/Users/alex/projects/AGENTS.md` and the relevant repo
README / runbook / topic docs for the change surface before reviewing.

## Preconditions

The supervisor handed you a task slug, its PR (base `accepted`), branch, repos,
risk tags, acceptance criteria, and the checks already reported. If any of that
is missing, note it as a finding — do not guess.

## Procedure

1. **Narrate as your own soul — before any review work.** Open a soul-attributed
   activity so the Alex heartbeat's Agent column attributes the review to you, not
   the base session mascot:

   ```bash
   bin/agent-activity start --category Verify --agent <your-soul> --task <task-slug> --reason "review: <task-slug>"
   ```

2. **Deep review.** Go deep on the change surface (use the strongest model on
   `migration` / `payment` / `solana` / `auth` risk tags):
   - **diff vs. acceptance** — the change does what the task's acceptance criteria say.
   - **checks / tests (you own this gate)** — the shape's Definition-of-Ready
     **base** tiers are green in `checks_run`; run the review gate-zero

     ```bash
     bin/dor-check <task-slug> --gate-role review
     ```

     and confirm it passes. This gate is yours, not the light's. The
     `--gate-role review` flag matters twice: your verdict lands as a SOP on
     the task's **G2a Primary** gate attempt
     ([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md))
     instead of closing the builder's **G1 Cert** — a bare `bin/dor-check
     <task-slug>` would stamp the builder's gate as if the builder ran it —
     and it keeps the **strict CI semantics**: builders submit without waiting
     for CI (their submit-side run credits a fast cert provisionally while CI
     is pending), so YOUR run is the authoritative CI verdict — red and
     still-running both block, and fast-cert evidence needs the settled green.
   - **your domain checklist** — walk your soul's REVIEW CHECKLIST (in your
     `role.md`) against the diff for the hard-won gotchas in your domain.
   - **code standards + code smell + scalability** — read the diff and the changed
     files, not just the summary; flag correctness bugs, unsafe patterns, and
     scaling cliffs.
   - **merge safety** — the branch could not overwrite or conflict with another
     agent's in-flight work.
   - **docs** — behavior / env / ports / auth / deploy / agent-ops changes carry
     doc updates in the same PR.

3. **Classify findings** as blockers, non-blockers, or questions.

4. **Record your scout report on the task** (drop `--dry-run` once the payload
   looks right):

   ```bash
   bin/devops-cycle --record-scout-report <task-slug> --scout-agent <your-soul> \
     --outcome <merge-ready|wait-for-ci|request-changes|conductor-review> \
     --summary "..." --finding "..." --check "..." --dry-run
   ```

   - **merge-ready** — no blockers; you recommend the supervisor advance the task.
   - **request-changes** — a defect; the supervisor will `block` it back to the builder.
   - **wait-for-ci** — CI is still running; the supervisor defers and re-queries.
   - **conductor-review** — low confidence (the humility valve); route to a human
     Avi / Steffon session instead of an auto-decision.

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
- [`pr-review-light.md`](pr-review-light.md) — the focused second-read role SOP
  your sibling runs.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) —
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md) —
  the G2 Review gate your lane (G2a) records into.
