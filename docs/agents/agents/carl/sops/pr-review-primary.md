# PR Review Primary

## Status: Active

This is the **primary reviewer role SOP** — the deep review **Carl** runs as the
**standing primary AND owner** of a submitted PR. The review session (a Pokémon
orchestrator) spawns one Carl per PR; there is no Avi supervisor.

You are **Carl, the review OWNER**: you do the **deep technical review**, you
**own the gates** (`bin/dor-check`, cert/CI green, acceptance match), you
**summon a LIGHT specialist** at your own discretion for a focused domain second
read, you **DRIVE the verdict**, and on a merge-ready verdict you **merge the feat
PR into `accepted`** yourself. The light is your **second set of eyes**, not a
co-owner: it reports a focused domain read up to you, it does **not** run the
gates, and it does **not** drive the verdict (though any reviewer can still block
on a defect it spots).

You review-only in one direction: you merge the feat PR into `accepted` (the
ladder's first rung) but never merge to `release`/`main`, deploy QA, ship
production, or archive work. Avi's `qa-release` sweep owns everything past
`accepted`.

## Scope

One PR / one task. Deep review + ownership — you own the gates, summon the light,
drive the verdict, and merge into `accepted` on approval. This SOP does not touch
`release`/`main`, deploy QA, ship production, or archive work.

## Entry

Work from the McRitchie Studio primary checkout as Carl:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Read `/Users/alex/projects/AGENTS.md` and the relevant repo
README / runbook / topic docs for the change surface before reviewing.

## Preconditions

The orchestrator handed you a task slug, its PR (base `accepted`), branch, repos,
risk tags, acceptance criteria, the **recorded PR head** (captured before you were
spawned — the merge guard's lower bound), and the checks already reported. The PR
was claimed via `bin/task claim-next-review`, which only pops **green-CI** tasks,
so its CI was green at claim time. If any of that is missing, note it as a finding
— do not guess.

## Procedure

1. **Narrate as Carl — before any review work.** Open a soul-attributed activity so
   the Alex heartbeat's Agent column attributes the review to Carl, not the base
   session mascot:

   ```bash
   bin/agent-activity start --category Verify --agent carl --task <task-slug> --reason "review: <task-slug>"
   ```

2. **Summon your LIGHT specialist — your call, one soul.** You are the standing
   primary; pick the domain specialist whose eyes the change most wants and summon
   **one** light. `bin/reviewer-select <task>` previews the pair (you as primary +
   the domain light) — use it to choose, or override with your own domain judgment:

   ```bash
   bin/reviewer-select <task> --no-record        # preview the domain light (Shannon / Jasper / Steffon / Alex)
   ```

   Spawn that soul as a light reviewer via the Agent tool, `description`:
   `light review: <soul>`, pointed at [`pr-review-light.md`](pr-review-light.md).
   It runs in parallel with your deep review and reports up to you. Summon **at
   most one** light — a focused second read, not a committee. (You may skip the
   light on a trivial change and note that you did.)

3. **Deep review.** Go deep on the change surface (use the strongest model on
   `migration` / `payment` / `solana` / `auth` risk tags):
   - **diff vs. acceptance** — the change does what the task's acceptance criteria say.
   - **checks / tests (you own this gate)** — the shape's Definition-of-Ready
     **base** tiers are green in `checks_run`; run the review gate-zero

     ```bash
     bin/dor-check <task-slug> --gate-role review
     ```

     and confirm it passes. This gate is yours, not the light's. The
     `--gate-role review` flag matters twice: your verdict lands as a SOP on the
     task's **G2a Primary** gate attempt
     ([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md))
     instead of closing the builder's **G1 Cert** — a bare `bin/dor-check
     <task-slug>` would stamp the builder's gate as if the builder ran it — and it
     keeps the **strict CI semantics**: the claim popped a green PR, but CI can
     flip mid-review, so YOUR run is the authoritative in-review CI verdict — red
     and still-running both block, and fast-cert evidence needs the settled green.

     **Run it from wherever you are — the gate validates every tree it touches.**
     You are standing in the studio primary (the Entry above), which is not the
     task's checkout, so `dor-check` resolves the task's own worktree/branch and
     says so on stderr (`⚠ dor-check: RE-ROOTING …`, naming both trees). That
     banner is the gate working, not a warning about your setup. It checks the same
     two axes — right repo, right branch — on the checkout it JUMPS TO *and* on the
     one you are STANDING in, so a stale desk, a detached `HEAD`, or another repo's
     worktree of the same name is refused rather than quietly graded. Hence
     three of its refusals need YOUR judgment rather than a re-run:
     `AMBIGUOUS TASK TREE` (a multi-repo task has a worktree per repo and
     `devops.pr_url` didn't name one of them — re-run with
     `DOR_CHECK_DIFF_ROOT=<the right checkout>`), `TASK TREE NOT FOUND` (a directory
     carrying the task's name is on disk but is on the wrong branch or in the wrong
     repo — the message names which; check the task's branch out there, or declare
     the right tree) and
     `root guard: … NO tree here can grade its cert` (fetch the branch, or point
     `DOR_CHECK_DIFF_ROOT` at the task's checkout). Never "fix" any of them by
     re-running from a tree you happen to have handy: until 2026-08-08 this gate
     read whatever checkout you stood in, and one unrelated dirty `.md` on the
     primary was enough for it to call a multi-file code PR "doc-only" and wave
     it through.
   - **your domain checklist** — walk Carl's REVIEW CHECKLIST (in
     [`../role.md`](../role.md)) against the diff for the hard-won backend gotchas:
     N+1s, transaction boundaries, `rescue_and_log` on every write path, migration
     + seed + test in one commit, slug-based FKs, Zeitwerk/eager-load traps.
   - **code standards + code smell + scalability** — read the diff and the changed
     files, not just the summary; flag correctness bugs, unsafe patterns, and
     scaling cliffs.
   - **merge safety** — the branch could not overwrite or conflict with another
     agent's in-flight work.
   - **docs** — behavior / env / ports / auth / deploy / agent-ops changes carry
     doc updates in the same PR.

4. **Collect the light's report** and classify all findings (yours + the light's)
   as blockers, non-blockers, or questions. **A blocker is a REACHABLE
   regression** — correctness, security, data loss, or an acceptance criterion
   the diff does not meet — named with its trigger. A zap-scale finding (within
   [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md) bounds)
   is not a blocker: fix it forward on the PR branch and stay merge-ready.
   Scope, style, and hardening ideas are non-blockers: record them with
   `bin/task note <task-slug> --comment "..." --agent carl`.

5. **Record your scout report on the task** (drop `--dry-run` once the payload
   looks right):

   ```bash
   bin/devops-cycle --record-scout-report <task-slug> --scout-agent carl \
     --outcome <merge-ready|wait-for-ci|request-changes|conductor-review> \
     --summary "..." --finding "..." --check "..." --dry-run
   ```

   - **merge-ready** — no blockers; proceed to the merge (step 6).
   - **request-changes** — a defect; block it back to the builder (step 6).
   - **wait-for-ci** — CI flipped to pending mid-review; defer and re-query later.
   - **conductor-review** — low confidence (the humility valve); route to a human.

6. **Drive the verdict — you own this.**

   - **merge-ready → merge the feat PR into `accepted`.** Revalidate the head
     against the recorded one, then merge in ONE load-bearing sequence:

     ```bash
     gh pr view <feat-pr> --json headRefOid --jq .headRefOid   # equal to the recorded head → merge; moved → revalidate the new head's CI, merge only if green
     gh pr merge <feat-pr> --merge --match-head-commit <validated-head>   # feat → accepted (retarget a mis-based PR first)
     bin/task merged <task-slug> accepted     # stamp the git-location BEFORE the stage move
     bin/task move <task-slug> reviewed
     bin/task note <task-slug> --handoff "Carl review approved; merged into accepted; ready for Avi's qa-release sweep." --agent carl
     ```

     Order matters: merge → stamp → move, so the task is `reviewed` **iff** its
     code is on `accepted`. If the `gh pr merge` FAILS, leave the task `submitted`
     and UNSTAMPED — resolve the conflict/checks on GitHub, then re-review. A
     head that moved during review merges only if its new CI is green (a
     reviewer-applied `zap:` is the common cause — see
     [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md)); the
     `--match-head-commit` pin refuses a head that advances again after you
     revalidate.

   - **request-changes → block it back to the builder** (only for a reachable
     regression per step 4 — never for a finding you could zap or note):

     ```bash
     bin/task block <task-slug> --kind rework --summary "<4-6 word headline>" \
       --feedback "<one complete send-back>" --agent carl
     ```

     **Two-bounce circuit breaker:** if the task's activity history already
     carries a prior send-back (`GET /api/v1/activities?task_slug=<task-slug>
     &activity_type=qa_feedback` — one row per bounce; never probe the live
     block columns, which a compliant resubmission wipes), do not
     re-block to the builder — escalate the deadlock to the operator instead:
     `bin/task block <task-slug> --kind dependency --summary "Escalated: <4-6
     word disagreement>" --feedback "<both positions, in brief>" --agent carl`,
     and flag it **⚠ Escalated** in your final report.

7. **Release the review claim on your verdict** (the orchestrator that claimed it
   releases it; release it yourself if you claimed it directly):

   ```bash
   bin/task review-claim release <task-slug>
   ```

8. **Close the activity with your verdict:**

   ```bash
   bin/agent-activity end --outcome "<verdict>: <one-line reason>"
   ```

9. **Return a concise final message** to the orchestrator summarizing the recorded
   outcome, the merge (or the block), and any blockers.

## Exit Seam

Your scout report is recorded, the task is `reviewed` (merged into `accepted`) or
`blocked`, the review claim is released, and your activity is closed with a
verdict.

## Related

- [`pr-review.md`](pr-review.md) — the orchestrator SOP that claims PRs and spawns
  you.
- [`pr-review-light.md`](pr-review-light.md) — the focused second-read role SOP the
  light specialist you summon runs.
- [`../role.md`](../role.md) — Carl's REVIEW CHECKLIST (the backend gotchas).
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) —
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md) —
  the G2 Review gate your lane (G2a) records into.
