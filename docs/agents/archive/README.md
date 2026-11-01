# Frozen docs archive

The frozen history that lived here was removed on 2026-11-01, on Alex McRitchie's
ruling. Git keeps every file. Read one at the commit that last held it:

```bash
git show d3a02a15d008:docs/agents/archive/<path>
git ls-tree -r --name-only d3a02a15d008 docs/agents/archive
```

A live page that names a dated file here, such as `fast-lane-2026-09-25.md`, means
that path at this commit. The Rex pages and briefs are under `agents/rex/`.

What stays in the tree:

- [`prototypes/`](prototypes/README.md): `acquisition-studio.bundle`. The repo's
  GitHub origin is gone, so this bundle is the only copy off the laptop. Never delete it.

The delete-later ledger and its archive of closed rows were retired on 2026-11-01. Read them
at `ded736a70c06`; [`parking-lot.md`](../maintenance/parking-lot.md#retired-delete-later-ledger) has the commands.

`bin/archive-docs` still moves dated docs here on the archive beat, so new files can appear.
