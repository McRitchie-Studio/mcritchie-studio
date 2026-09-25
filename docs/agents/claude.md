# CLAUDE.md — Claude Code adapter for the McRitchie operating model

Claude Code auto-loads this file, not `AGENTS.md`, so this adapter carries the
gate that must not be missed and then imports the map. Read both before acting.
The long form this adapter replaced is kept verbatim in
`mcritchie-studio/docs/agents/archive/entry-docs-2026-09-24.md`.

## SOPs are commands

If Alex's prompt names an SOP or heartbeat act such as `pr-review`, `qa-release`,
`production-deploy`, `focus-session`, `building-sop`, `arbitrate-block`,
`credential-rotation`, `clean-up`, `process-backlog`, `work-backlog`, or
`full-cycle`, resolve that phrase through the SOP registry in `AGENTS.md`, read
the mapped file first, then execute it. `pr-review` means read
`mcritchie-studio/docs/agents/agents/carl/sops/pr-review.md`, not `bin/pr-review --help`.

## ⛔ STOP — before writing ANY code

Any diff (feature, bug, or chore, however small) runs the DevOps cycle. There is
no size exemption. Name the hub's script and stand in the desk:

```bash
/Users/alex/projects/mcritchie-studio/bin/task begin --title "Three To Five Words" --agent <soul> \
  --repo <app> --kind <kind> \
  --shape <shape> --risk <tag> --accept "criterion" --test "[unit] ..."

cd <desk>   #   ... the worktree begin printed; build there ...

/Users/alex/projects/mcritchie-studio/bin/ship-wait <task-slug> --launch -m "Commit message"
```

- Write the test tiers your shape requires as you go, unit-first.
- `bin/ship` stops at `submitted`. Never merge, deploy, or push `main` unless Alex
  assigned you that lane in this session.
- Detail: `mcritchie-studio/docs/agents/modules/building-sop.md`.

## GitHub auth is self-service

On `Bad credentials`, a 401, or a `gh auth login` prompt, run
`eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` and
retry. Never ask Alex to run `gh auth login`. If that fails, run the
`token-session` SOP.

---

## Full operating model

@AGENTS.md
