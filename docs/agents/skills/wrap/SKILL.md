---
name: wrap
description: Shared session-close ceremony for Claude and Codex. Invoke when a session is wrapping up — the user signals they're done or asks what's left ("anything else?", "we're good", "call it here", "wrap up", "/wrap"), or you're handing off. First offers the highest-leverage work the session's warm context unlocks, then walks memory hygiene, a documentation sweep, task-board reconciliation, and worktree/stack status, and ends by handing the operator permission to close at a clean seam — so the warm context is spent well and end-of-session cleanup happens by ritual, not by luck.
---

# Shared /wrap — session-close ceremony

A bumper for the end of a session. Work the steps top to bottom. Skip one only if
it plainly doesn't apply — and say so out loud rather than silently dropping it.
Each step should end in something inspectable. Keep it honest: "nothing to do" beats
narrating busywork; surface operator-gated steps, don't perform them.

**Ethos — doing the right thing is always the right answer.** A wrap is not a dash
for the exit. It's the moment to spend the session's warm context *well* before it's
gone: you hold this code, these patterns, this state loaded **right now**, and the
next session starts cold. So a wrap pulls two ways at once, and both are the job —
feel free to do each without waiting to be asked:
- **Offer the work the warm context unlocks.** Don't just tidy and leave; name the
  highest-leverage thing worth doing while you're still warm (Step 1).
- **Earn, then hand over, the close.** When you reach a genuinely clean seam, tell
  the operator plainly that they're clear to close (Step 8).

**Always be closing** — toward the *right* close, never a hurried one.

Absolute paths used below:
- McRitchie studio: `/Users/alex/projects/mcritchie-studio`
- Claude memory dir, when running under Claude:
  `/Users/alex/.claude/projects/-Users-alex-projects/memory`
- Codex memory dir: none is platform-owned yet. Use only an explicitly provided
  writable memory directory; otherwise capture durable facts in the task record,
  active docs, or the final handoff.
- `<memory dir>` means the selected runtime memory directory, when one exists.

## 1. Spend the warm context
Before you tidy, ask what this session is uniquely positioned to do **right now**.
You hold loaded context the next cold session won't — the files you read, the
patterns you learned, the things you noticed in passing. Surface the highest-leverage
moves it unlocks, ranked, and offer them; you don't need permission to suggest:
- an adjacent fix, test, or doc you noticed but didn't do;
- a backlog or `stale` task this context would make cheap;
- the natural next increment of the work just done.
The operator picks one (→ do it, then re-enter the wrap) or waves you on to close.
Don't manufacture busywork: if there is genuinely nothing worth it, **say so** —
"nothing worth doing warm" is a finding you looked for, not a step you skipped.

## 2. Capture learnings → memory
Ask: what did this session teach that is durable AND non-obvious — a gotcha, a
decision, a project-state change, a stated preference?
- Select the memory target first. Under Claude, use the Claude memory dir above.
  Under Codex, use an explicit writable memory dir only if one is provided; if no
  memory target exists, say so and capture durable facts through the task record,
  active docs, or handoff instead of inventing a private store.
- When a memory dir exists, write or update memory files there.
- **Consolidate** into an existing file rather than spawning a near-duplicate;
  **delete** memories that turned out wrong or superseded.
- Don't save what the repo / git history / agent entry docs already record.
- Every new or updated memory gets exactly ONE terse index line in `MEMORY.md`:
  `- [Title](file.md) — <≤130-char hook>`. Detail lives in the topic file, never
  in the index. (See `feedback_memory_index_hygiene.md`.)

## 3. Memory index hygiene
Run this only when a memory dir exists. Keep `MEMORY.md` under its size limit
(~24KB) so the harness loads the whole index. The job: shorten the one-line
hooks — never the links or the topic files — so every entry stays terse and the
file stays under the cap.
- `wc -c <memory dir>/MEMORY.md`
- If it's near or over the cap, trim the index. A trimmer at
  `<memory dir>/bin/trim-index` automates it — **use it WHEN PRESENT**, but don't
  block the wrap on its absence (the memory-hygiene tooling is not yet
  platform-owned, so a fresh machine may not have it):

  ```bash
  if [ -x "<memory dir>/bin/trim-index" ]; then
    "<memory dir>/bin/trim-index" 130   # only shortens hooks; links + topic files untouched
  else
    echo "trim-index not installed — trim the longest index hooks to ≤130 chars by hand"
  fi
  ```

  When the tool is absent, do the same edit by hand: shorten the longest index
  hooks to ≤130 chars until the file is back under the cap.
- Verify either way: bytes down, entry count unchanged, and every index line still
  links — `grep -E '^- \[' MEMORY.md | grep -v '](' | wc -l` prints `0` (the count
  of link-less index lines). Use `wc -l`, **not** `grep -c`/`-vc`: a zero `grep -c`
  count exits non-zero — the success case — which short-circuits the check when you
  chain it under `&&`.

## 4. Documentation sweep
Did this session change behavior, a workflow, ports, auth, env vars, deploy steps,
or an agent process? If yes, update the OWNING active doc in this same wrap — stale
docs are how the next session starts from a wrong map.
- A McRitchie active-doc edit is a code diff → route it through the DevOps cycle
  (task → worktree → PR into `release`), per `AGENTS.md` and any generated
  runtime adapter. Do **not** edit McRitchie active docs on a primary checkout.

## 5. Task-board reconciliation
- `cd /Users/alex/projects/mcritchie-studio && bin/task stale` — flags any task whose
  work already shipped but that isn't `shipped`/`archived`.
- Confirm every task you touched is in its correct stage. Nothing stranded in
  `building` (a leaked claim) or left un-`submitted` when its PR is open.

## 6. Worktree / stack status
- Report **this session's** worktree stacks in full — any still serving (ports), so
  the operator can reclaim them. `bin/agent-worktree list` for the picture.
- Other sessions' stacks holding ports get a **one-line note** (count + ports), not
  a full audit — on a shared machine the list runs long and most of it isn't yours.
- Do **not** delete worktrees or branches whose PRs aren't merged or abandoned.

## 7. Handoff
Close with an inspectable summary:
- Task URLs **before** PR URLs (lead from the task record), plus local/QA URLs.
- What's done and verified vs. what's open and owed.
- Any operator-gated next step (QA review, merge, deploy) — named, not taken.

## 8. Clear to close
Make the call — this is the last word, and it's yours to offer. If you're at a
genuinely clean seam — work committed or safely parked, the board honest, nothing
half-done that a cold session would fumble — say it plainly: **"Clean seam — you're
clear to close."** If you're *not* there yet, name the single thing that would get
there, so the operator is never left guessing whether it's safe to stop. Doing the
right thing is always the right answer; sometimes that's one more move, and sometimes
it's handing the operator a clean exit. Always be closing.
