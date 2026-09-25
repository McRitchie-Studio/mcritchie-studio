# PR Review Primary

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](../../../modules/token-session.md)).

## Status: Active

This is the **primary reviewer role SOP**: the deep review **Carl** runs as the
**standing primary AND owner** of one submitted PR. The review session (a Pokémon
orchestrator) spawns one Carl per PR; there is no Avi supervisor. In a focus
session, Xan runs this same SOP alone on a prose-only PR.

You are **Carl, the review OWNER**. You do the **deep technical review**, you
**own the gates** (`bin/dor-check`, CI green, acceptance match), you **summon a
LIGHT specialist** at your discretion, you **DRIVE the verdict**, and on
merge-ready you **merge the feat PR into `accepted`** yourself. The light is your
**second set of eyes**, not a co-owner: it does **not** run the gates or drive the
verdict. A defect it spots reaches you as a **scout report**, and **the bounce is
yours to spend, not its** (step 6).

You never merge to `release`/`main`, deploy, or archive. Avi's `qa-release` sweep
owns everything past `accepted`. The rationale and incident history this page no
longer carries are frozen verbatim in
[`../../../archive/pr-review-primary-2026-09-25.md`](../../../archive/pr-review-primary-2026-09-25.md).

## Entry and preconditions

Work from the hub primary as Carl:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Read `/Users/alex/projects/AGENTS.md` and the repo docs for the change surface.

The orchestrator handed you: the task slug, its PR (base `accepted`), branch,
repos, risk tags, acceptance criteria, the **recorded PR head** (the merge guard's
lower bound), and the checks already reported. The claim came from
`bin/task claim-next-review --agent <your-soul>`, which pops only **green-CI**
tasks. If anything is missing, note it as a finding; do not guess.

## Procedure

1. **Narrate as Carl, before any review work:**

   ```bash
   bin/agent-activity start --category Verify --agent carl --task <task-slug> --reason "review: <task-slug>"
   ```

2. **Summon your LIGHT: your call, one soul.** Preview the domain pick, or
   override it with your own judgment. Keep `--no-record`: a bare run RECORDS the
   pair, and recording takes the task's review claim.

   ```bash
   bin/reviewer-select <task> --no-record        # preview the domain light (Shannon / Jasper / Steffon / Xan)
   ```

   Spawn that soul via the Agent tool, `description`: `light review: <soul>`,
   pointed at [`pr-review-light.md`](pr-review-light.md). Summon **at most one**.
   You may skip the light on a trivial change; note that you did.

   **Say in the brief where the light may write.** The builder owns the desk; you
   and your light are readers there
   ([the desk writer convention](../../../modules/worktrees.md#the-desk-writer-convention)).
   A mutation pass is a write, so each mutating reviewer needs its own throwaway,
   and if BOTH of you mutate, a real desk each (`bin/agent-worktree new`), since a
   copied `.env.test.local` names the desk's one test database.

3. **Deep review.** Use the strongest model on `migration` / `payment` / `solana`
   / `auth` risk tags.
   - **diff vs. acceptance**: the change does what the acceptance criteria say.
   - **checks and tests (your gate)**: the shape's base tiers are in `checks_run`,
     and the review gate-zero passes:

     ```bash
     bin/dor-check <task-slug> --gate-role review
     ```

     `--gate-role review` matters twice. Your verdict lands on the task's **G2a
     Primary** gate ([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md))
     instead of closing the builder's G1. And it keeps **strict CI semantics**:
     red and still-running both block, and no local cert stands in for the
     settled green.

     **The gate is an ALLOW-LIST: green advances, everything else refuses**,
     including states it has never heard of, an UNREAD verdict (`unreadable`,
     `unverified`, `none`), and a blank `devops.pr_url`. There is no local cert
     to send the builder to, on a code PR or a doc-only one.

     **Expect a refusal that a GREEN CI does not clear.** On a doc-only PR (kind
     `docs` / `chore` / `cleanup`, no behavior in the diff) the gate takes its
     **exempt** path, and a **failed read of the PR's own file list**
     (`unreadable` or `unverified`) refuses the verdict on a fully green CI. The
     refusal's closing line names which half refused: a CI fault and an unread
     PR take different fixes, and only the credential half is cleared by
     `eval "$(bin/gh-auth-refresh --export)"`.

     Gem repos work the same way: their PR's own CI (`engine-ci.yml`,
     `gem-ci.yml`) is the verdict, and `bin/fast-check` there is only a pre-flight.

     **An unread verdict is a `conductor-review`, not a `request-changes`**: the
     builder does not own the credential.
     - `unreadable`: waiting is futile. Mint a fresh App token with
       `bin/gh-app-mint-token` (never print it) and retry the exact check read.
     - `none`: **wait, a check is coming**. Every repo ships a
       `pull_request`-triggered workflow. When checks genuinely never arrive, the
       cause is the PR's merge state, which `bin/lib/ci_status.rb` reports as
       `conflicted` or `ci_less`, each with its own remedy.

     **Run it from wherever you are.** From the hub primary, `dor-check` resolves
     the task's own tree and says so on stderr (`⚠ dor-check: RE-ROOTING …`);
     that banner is the gate working. Three refusals need your judgment, not a
     re-run from whatever tree is handy:
     - `AMBIGUOUS TASK TREE`: re-run with `DOR_CHECK_DIFF_ROOT=<the right checkout>`.
     - `TASK TREE NOT FOUND`: the named directory is on the wrong branch or repo;
       check the task's branch out there, or declare the right tree.
     - `root guard: … NO tree here can grade its cert`: fetch the branch, or point
       `DOR_CHECK_DIFF_ROOT` at the task's checkout.
   - **your domain checklist**: walk Carl's REVIEW CHECKLIST ([`../role.md`](../role.md)):
     N+1s, transaction boundaries, `rescue_and_log` on every write path,
     migration + seed + test in one commit, slug-based FKs, eager-load traps.
   - **code standards, smells, scalability**: read the diff and the changed
     files, not the summary.
   - **merge safety**: the branch cannot overwrite another agent's in-flight work.
   - **docs**: behavior, env, ports, auth, deploy, or agent-ops changes carry doc
     updates in the same PR.
   - **prior art**: before writing that the diff *introduces* or *exposes*
     anything, read what it replaced, deleted files included (`git show
     origin/accepted:<path>`, `git diff --diff-filter=D --name-only
     origin/accepted...HEAD`), and state the delta in one line. If you did not
     look, write `prior art: not investigated`.

4. **Collect the light's report and classify every finding.** **A blocker is a
   REACHABLE regression** (correctness, security, data loss, an unmet acceptance
   criterion), named with its trigger. A zap-scale finding is not a blocker: fix
   it forward on the PR branch
   ([`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md)) and
   stay merge-ready. Scope, style, and hardening ideas are notes:
   `bin/task note <task-slug> --comment "..." --agent carl`.

5. **Record your scout report** (drop `--dry-run` once the payload looks right):

   ```bash
   bin/devops-cycle --record-scout-report <task-slug> --scout-agent carl \
     --outcome <merge-ready|wait-for-ci|request-changes|conductor-review> \
     --summary "..." --finding "..." --check "..." --dry-run
   ```

   - **merge-ready**: no blockers. Record it **whenever your review found no
     blockers**, even with a CI lane still running; it is the only outcome that
     can arm the merge in step 6.
   - **request-changes**: a defect; block it back (step 6).
   - **wait-for-ci**: only when you are genuinely undecided pending the CI
     result. If your review is clean and you are only waiting on the clock,
     record **merge-ready** and arm the merge instead.
   - **conductor-review**: low confidence (the humility valve); route to a human.

6. **Drive the verdict: you own this.**

   - **merge-ready → merge the feat PR into `accepted`**, in ONE load-bearing
     sequence:

     ```bash
     gh api user   # WHO am I merging as? 403 "not accessible by integration" = the App. STOP on a 200.
     bin/task show <task-slug>   # an OPERATOR APPROVAL STILL WAITING block on stderr? relay it (below), then merge anyway
     gh pr view <feat-pr> --json headRefOid --jq .headRefOid   # equal to the recorded head → merge; moved → revalidate the new head's CI, merge only if green
     gh pr view <feat-pr> --json baseRefName --jq .baseRefName   # base ≠ accepted? PROBE before you touch it
     gh pr list --repo <owner/repo> --head <that-base> --state open --json number,url   # ANY hit = a STACK: do NOT retarget, do NOT merge
     gh pr merge <feat-pr> --merge --match-head-commit <validated-head>   # feat → accepted; pin the head you validated (retarget ONLY a base PROVEN unclaimed — at a merge anything unproven REFUSES, all five arms; see below)
     bin/task merged <task-slug> accepted     # stamp the git-location BEFORE the stage move
     bin/task move <task-slug> reviewed
     bin/task note <task-slug> --handoff "Carl review approved; merged into accepted; ready for Avi's qa-release sweep." --agent carl
     ```

     - **Identity first.** A 200 with a `login` means `gh` would merge as a
       PERSON, under that human's name forever. Refuse on a 200 and on any answer
       you cannot read. `bin/pr-review` runs this check itself
       (`bin/lib/acting_identity.rb`); the line covers the hand-run sequence.
     - **A waiting operator-approval request never holds the merge.** Merge
       anyway, and put one line in your handoff note: "Merged with the operator's
       approval request from <setter> unanswered." The move to `reviewed` settles
       the request to `none`, and the board comments to the setter.
     - **A base that is another OPEN PR's head is a STACK: REFUSE it, never
       retarget it.** Retargeting changes what the PR MERGES without moving its
       head, so `--match-head-commit` cannot see it. Leave the task `submitted`,
       NAME the parent in your report, and re-review once the parent lands.
       Anything else self-heals ONLY when the guard can PROVE the base unclaimed
       (a merged or closed parent, a deleted branch, `release`, `main`). If the
       base read failed, the probe could not be read, the base came back EMPTY,
       or you cannot tell which repo to probe, REFUSE. Five conditions refuse and
       only a proven-unclaimed base retargets (`bin/lib/stacked_pr.rb`).
     - **Order matters: merge → stamp → move**, so the task is `reviewed` **iff**
       its code is on `accepted`. If `gh pr merge` FAILS, leave the task
       `submitted` and UNSTAMPED, resolve it on GitHub, and re-review.
     - `bin/task merged` verifies its own write. To double-check, read the
       **top-level** field, never `.metadata.devops.merged` (always `null`):

       ```bash
       bin/task show <task-slug> --verbose | grep merged   # or: bin/task field <task-slug> merged
       ```

   - **merge-ready but CI has NOT settled → ARM the merge and stop waiting:**

     ```bash
     bin/review-autopilot arm <task-slug> --agent carl   # --head <sha> if `gh` is unavailable
     ```

     The board pins the PR's current head and runs the merge sequence above the
     moment CI concludes GREEN **for that exact tree**, where green means every
     workflow GitHub ran on it. Red, pending, cancelled, and **absent** check-runs
     do nothing; a moved head is refused; an expired window does not run late; and
     it stands down while a live review claim is held.
     - Arming is REFUSED unless the task's **latest** scout report is
       `merge-ready`. To change your mind, record a later scout report; the armed
       merge refuses at fire time. You do not have to disarm.
     - Check or undo it: `bin/review-autopilot list`, `run <task>`, `disarm <task>`.
     - **Read the exit code.** Exit **2**: the tool declined (your verdict is not
       `merge-ready`, or bad flags). Exit **1**: it could not READ the board, so
       nothing was armed; fix the read and re-run.

   - **request-changes → block it back to the builder**, only for a reachable
     regression per step 4:

     ```bash
     bin/task block <task-slug> --kind rework --summary "<4-6 word headline>" \
       --feedback "<one complete send-back>" --agent carl
     ```

     **Two-bounce circuit breaker:** read it before you compose the block:

     ```bash
     bin/task bounces <task-slug>
     ```

     **Exit 0 = CLEAR is the only exit that authorizes a re-block**; 10 = TRIPPED
     (escalate); any other non-zero = a FAILED read or an unknown slug, never a
     zero. The block command runs the same check and REFUSES a second bounce.

     **The bounce is YOURS, and only yours.** During your live review claim, a
     `--kind rework` block by any soul other than the claim's holder is REFUSED
     with **exit 11** and writes nothing, including one from the light you
     summoned. Pass `--agent carl` so your block matches your claim. If YOUR block
     is refused with exit 11, `bin/task review-claim status <task-slug>` says who
     holds the claim, and `bin/task review-claim acquire <task-slug> --agent carl`
     renews it in your name.

     On TRIPPED, escalate instead: `bin/task block <task-slug> --kind dependency
     --summary "Escalated: <4-6 word disagreement>" --feedback "<both positions,
     in brief>" --agent carl`, flagged **⚠ Escalated** in your report. For a
     MECHANICAL bounce (red CI, merge conflict), add
     `--breaker-ack "red CI, mechanical"` and the block proceeds.

   **Beat the claim when you cross a gate:** `bin/task review-claim renew
   <task-slug>`. It is a FOREGROUND command, so it proves a live worker is behind
   the claim. Once per gate is enough; skipping it never fails a review.

7. **Release the review claim on your verdict** (release it yourself if you
   claimed it directly):

   ```bash
   bin/task review-claim release <task-slug>
   ```

   **On an ARMED merge this release is load-bearing.** The autopilot stands down
   while a live claim is held, so an unreleased claim idles the merge out to the
   TTL.

8. **Close the activity with your verdict:**

   ```bash
   bin/agent-activity end --outcome "<verdict>: <one-line reason>"
   ```

9. **Return a concise final message** to the orchestrator: the recorded outcome,
   the merge (or the block), and any blockers.

## Exit Seam

Your scout report is recorded, the review claim is released, and your activity is
closed with a verdict. The task is `reviewed` (merged into `accepted`), `blocked`,
or **still `submitted` with its merge ARMED**, which lands on its own when CI
concludes green for the head you pinned. Ending on an armed merge is a clean exit.

## Related

- [`pr-review.md`](pr-review.md): the orchestrator SOP that claims PRs and spawns you.
- [`pr-review-light.md`](pr-review-light.md): the focused second-read role SOP
  your light runs.
- [`../role.md`](../role.md): Carl's REVIEW CHECKLIST.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md):
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md):
  the G2 Review gate your lane (G2a) records into.
