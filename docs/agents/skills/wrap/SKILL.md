---
name: wrap
description: Session-close ceremony / bumper. Invoke when a session is wrapping up — the user signals they're done or asks what's left ("anything else?", "we're good", "call it here", "wrap up", "/wrap"), or you're handing off. Walks memory hygiene, a documentation sweep, task-board reconciliation, worktree/stack status, and a handoff summary so end-of-session cleanup happens by ritual, not by luck.
---

# /wrap — session-close ceremony

A bumper for the end of a session. Work the steps top to bottom. Skip one only if
it plainly doesn't apply — and say so out loud rather than silently dropping it.
Each step should end in something inspectable. Keep it honest: "nothing to do" beats
narrating busywork; surface operator-gated steps, don't perform them.

Absolute paths used below:
- memory dir: `/Users/alex/.claude/projects/-Users-alex-projects/memory`
- McRitchie studio: `/Users/alex/projects/mcritchie-studio`

## 1. Capture learnings → memory
Ask: what did this session teach that is durable AND non-obvious — a gotcha, a
decision, a project-state change, a stated preference? Write or update memory files
in the memory dir.
- **Consolidate** into an existing file rather than spawning a near-duplicate;
  **delete** memories that turned out wrong or superseded.
- Don't save what the repo / git history / CLAUDE.md already records.
- Every new or updated memory gets exactly ONE terse index line in `MEMORY.md`:
  `- [Title](file.md) — <≤130-char hook>`. Detail lives in the topic file, never
  in the index. (See `feedback_memory_index_hygiene.md`.)

## 2. Memory index hygiene
Keep `MEMORY.md` under its size limit (~24KB) so the harness loads the whole index.
The job: shorten the one-line hooks — never the links or the topic files — so every
entry stays terse and the file stays under the cap.
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
  links — `grep -E '^- \[' MEMORY.md | grep -vc ']('` returns 0.

## 3. Documentation sweep
Did this session change behavior, a workflow, ports, auth, env vars, deploy steps,
or an agent process? If yes, update the OWNING active doc in this same wrap — stale
docs are how the next session starts from a wrong map.
- A McRitchie active-doc edit is a code diff → route it through the DevOps cycle
  (task → worktree → PR into `release`), per `CLAUDE.md`. Do **not** edit McRitchie
  active docs on a primary checkout.

## 4. Task-board reconciliation
- `cd /Users/alex/projects/mcritchie-studio && bin/task stale` — flags any task whose
  work already shipped but that isn't `shipped`/`archived`.
- Confirm every task you touched is in its correct stage. Nothing stranded in
  `building` (a leaked claim) or left un-`submitted` when its PR is open.

## 5. Worktree / stack status
- Report any worktree stacks still serving (ports) so the operator can reclaim them.
  `bin/agent-worktree list` for the full picture.
- Do **not** delete worktrees or branches whose PRs aren't merged or abandoned.

## 6. Handoff
Close with an inspectable summary:
- Task URLs **before** PR URLs (lead from the task record), plus local/QA URLs.
- What's done and verified vs. what's open and owed.
- Any operator-gated next step (QA review, merge, deploy) — named, not taken.
