# Preserved prototype repositories

A git bundle here is the **last copy** of a repository whose GitHub origin no
longer exists. The usual escape — "a pushed branch preserves the code" — does not
apply to these, so they are preserved as objects in this repo instead.

Restore one with **`--mirror`**, and not with a plain `git clone`:

```bash
git clone --mirror docs/agents/archive/prototypes/<name>.bundle /Users/alex/projects/<name>.git
```

`--mirror` is load-bearing, not a stylistic preference. A plain `git clone` checks
out one branch and leaves every other ref UNREFERENCED — the objects arrive, so a
`rev-list --all` looks reassuring, but the next `git gc` deletes them. Measured on
`acquisition-studio.bundle`: after `git gc --prune=now`, a plain clone holds **6 of
12** commits and all four of the refs named below are gone
(`fatal: Not a valid object name`), while a `--mirror` clone still holds **12 of 12**
with every ref intact. For a bundle that is the LAST copy, that difference is the
whole point of keeping it.

## acquisition-studio.bundle

Retired prototype, superseded by `mcritchie-industries`
(`docs/agents/modules/app-registry.md`, `config/satellites.yml`). The GitHub repo
`amcritchie/acquisition-studio` was deleted; the local checkout at
`/Users/alex/projects/acquisition-studio` outlived it.

Bundled 2026-08-26 from that checkout, `--all`. **12 commits, 11 refs**, 172K.

Verified before it was committed, rather than assumed:

- `git bundle verify` reports a complete history.
- A `--mirror` clone from the bundle keeps **all 12** commit objects and all 11
  refs, and survives `git gc --prune=now`. (A plain clone does not — see above.)
- The refs include work that is **not reachable from `main`** and exists nowhere
  else — `origin/release` (`c9e1f17`), `origin/accepted` (`b53a3be`), the CI
  workflow branch (`ee37b16`), and the smooth-load adoption (`f7d5f2c`).
- None of those 12 commits exist in `mcritchie-industries`, which was checked
  before this was called a last copy.

The local checkout and its leftover desk at
`/Users/alex/projects/.worktrees/acquisition-studio-scaffold-acquisition-studio`
are still on disk. Removing them is a deliberate operator decision, not a sweep's
— this bundle is what makes that decision reversible.
