# Archive Shipped

## Status: Active

This is Steffon's `archive-shipped` SOP. It closes out shipped work from prior
release cycles and reclaims completed worktrees. `archive-completed` is the
legacy name for this same act.

## Scope

Archive work only after it is already shipped. This SOP does not review PRs,
merge release work, deploy QA, or ship production.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

- At least one shipped task or completed release is ready to archive.
- The worktree cleanup candidate is merged or main-equivalent.
- No feature worktree with unmerged or dirty work is reclaimed.

If there is nothing to archive, report "nothing to archive" and stop.

## Procedure

Preview first:

```bash
bin/release archive --dry-run
```

If the preview matches the shipped/completed work you intend to close:

```bash
bin/release archive --yes
```

`--yes` only answers the non-interactive confirmation. It does not bypass archive
eligibility, worktree safety checks, release membership checks, or Redis-band
cleanup guards.

## Exit Seam

Shipped tasks and completed releases are archived, and safe completed worktrees
are reclaimed. Report:

- archived task count
- completed release count
- reclaimed worktrees
- any worktree intentionally left alone and why

On a clean no-op, report "nothing to archive."

## Related

- [`qa-release.md`](qa-release.md) - Steffon's release prepare SOP.
