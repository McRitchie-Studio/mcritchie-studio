# Preserved prototype repositories

A git bundle here is the **last copy** of a repository whose GitHub origin no
longer exists. The usual escape — "a pushed branch preserves the code" — does not
apply to these, so they are preserved as objects in this repo instead.

Restore one with:

```bash
git clone docs/agents/archive/prototypes/<name>.bundle /Users/alex/projects/<name>
```

## acquisition-studio.bundle

Retired prototype, superseded by `mcritchie-industries`
(`docs/agents/modules/app-registry.md`, `config/satellites.yml`). The GitHub repo
`amcritchie/acquisition-studio` was deleted; the local checkout at
`/Users/alex/projects/acquisition-studio` outlived it.

Bundled 2026-08-26 from that checkout, `--all`. **12 commits, 10 refs**, 172K.

Verified before it was committed, rather than assumed:

- `git bundle verify` reports a complete history.
- A clone from the bundle contains **all 12** commit objects from the original.
- The refs include work that is **not reachable from `main`** and exists nowhere
  else — `origin/release` (`c9e1f17`), `origin/accepted` (`b53a3be`), the CI
  workflow branch (`ee37b16`), and the smooth-load adoption (`f7d5f2c`).
- None of those 12 commits exist in `mcritchie-industries`, which was checked
  before this was called a last copy.

The local checkout and its leftover desk at
`/Users/alex/projects/.worktrees/acquisition-studio-scaffold-acquisition-studio`
are still on disk. Removing them is a deliberate operator decision, not a sweep's
— this bundle is what makes that decision reversible.
