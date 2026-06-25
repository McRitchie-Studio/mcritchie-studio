# User-global Claude Code skills (canonical source)

This directory is the **version-controlled home for the operator's user-global
Claude Code skills** — the same idea as the generated root `AGENTS.md`/`CLAUDE.md`:
McRitchie Studio owns the source so the skills survive a wiped machine and travel
with the platform.

## Layout

```
docs/agents/skills/
  <name>/
    SKILL.md         # required — the skill definition + frontmatter (name, description)
    ...              # optional helper scripts / reference files, also mirrored
```

Each `<name>/` becomes `~/.claude/skills/<name>/` on install. Files at the top
level of this directory (like this README) are **not** skills and are not
installed — the installer only mirrors files inside a `<name>/` subdir.

## Install / drift-check

`bin/install-agent-docs` mirrors this tree into `~/.claude/skills/*` (copy, not
symlink) alongside the root agent docs, and `bin/install-agent-docs check`
flags any local drift. It runs automatically in `bin/ecosystem-build` (Phase 5b)
on a fresh-machine rebuild.

```bash
bin/install-agent-docs          # AGENTS.md + CLAUDE.md + skills → local
bin/install-agent-docs check    # verify local matches the tracked sources
```

## User-global vs project-scoped

These are **user-global** skills — they load in every Claude Code session
regardless of CWD. The skills under `mcritchie-studio/.claude/skills/` are a
**separate, project-scoped** mechanism (they load only when CWD is the studio)
and are deliberately not managed by `bin/install-agent-docs`.

## Adding a skill

1. Create `docs/agents/skills/<name>/SKILL.md` (with `name:` + `description:`
   frontmatter).
2. Run `bin/install-agent-docs` to install it locally.
3. Commit through the normal DevOps cycle. A fresh machine restores it via
   `bin/ecosystem-build`.
