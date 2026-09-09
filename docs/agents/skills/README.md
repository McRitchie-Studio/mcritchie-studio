# User-global agent skills (canonical source)

This directory is the **version-controlled home for shared user-global agent
skills** — the same idea as the generated root `AGENTS.md`/`CLAUDE.md`:
McRitchie Studio owns the source so the skills survive a wiped machine and
travel with the platform.

## Layout

```
docs/agents/skills/
  <name>/
    SKILL.md         # required — the skill definition + frontmatter (name, description)
    ...              # optional helper scripts / reference files, also mirrored
```

Each `<name>/` becomes both `~/.claude/skills/<name>/` and
`~/.codex/skills/<name>/` on install. Files at the top level of this directory
(like this README) are **not** skills and are not installed — the installer only
mirrors files inside a `<name>/` subdir.

## Install / drift-check

`bin/agent-runtime install` mirrors this tree into `~/.claude/skills/*` and
`~/.codex/skills/*` (copy, not symlink) alongside the root agent docs and Codex
hooks; `bin/ecosystem-build` runs that install for you at Phase 5b on a
fresh-machine rebuild. `bin/agent-runtime check` reports local docs/skills drift
without writing anything.

```bash
bin/agent-runtime install       # FRESH-MACHINE BRINGUP ONLY — publishes globally
bin/agent-runtime check         # read-only: local docs/skills vs tracked sources
bin/agent-runtime doctor        # read-only: inspect marker/runtime hook state
```

`install` is listed for **fresh-machine bringup**, not for day-to-day use and
never as a response to a drift report — see the warning under
[Adding a skill](#adding-a-skill). `check` and `doctor` are read-only and safe
to run any time.

`bin/install-agent-docs` remains the lower-level copy/drift implementation that
`agent-runtime` calls.

The installer also prunes retired managed skills that used to live here. For
example, `qa-release` is now a plain launcher phrase in `AGENTS.md` and the
heartbeat docs, not an installed user-global skill.

## User-global vs project-scoped

These are **user-global** skills — fresh Claude and Codex sessions can load them
regardless of CWD. Runtime-specific project-scoped skills, such as
`mcritchie-studio/.claude/skills/`, are a **separate** mechanism and are
deliberately not managed by `bin/agent-runtime`.

## Adding a skill

1. Create `docs/agents/skills/<name>/SKILL.md` (with `name:` + `description:`
   frontmatter).
2. Commit through the normal DevOps cycle. A fresh machine restores it via
   `bin/ecosystem-build`.

**Do not install it by hand to try it out.** This tree publishes **globally** —
to `~/.claude/skills` and `~/.codex/skills`, which every session on the machine
loads — so a hand-run from a feature worktree pushes your unshipped skill, and
this branch's `AGENTS.md`/`CLAUDE.md` with it, to every other session. The
publish is owned: the `sync_agent_docs` step of `bin/release ship` runs it after
every production ship, so a new skill goes live on the ship that carries it. See
[`../modules/docs-maintenance.md`](../modules/docs-maintenance.md)
§ Editing The Entry Docs.
