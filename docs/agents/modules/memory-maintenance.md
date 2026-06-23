# Memory Maintenance

The agent auto-memory store is part of the recall surface for every session.
Keep it lean and accurate so the index loads in full — a bloated index degrades
recall for every agent, the way a bloated test suite degrades CI for every PR.
This is the memory analogue of test pruning
([`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §3.5):
same owner, same cadence, tracked like any other task.

## Where It Lives

The store sits at `~/.claude/projects/-Users-alex-projects/memory/`:

- **`MEMORY.md`** — the index. One line per memory, loaded into *every* session.
  Each line is a tight hook plus a link to the topic file:
  `- [Title](topic_file.md) — one-line summary`.
- **One topic file per memory** — the full detail. Each carries frontmatter:

  ```yaml
  ---
  name: short-handle
  description: one-sentence summary of the memory
  metadata:
    type: project        # or feedback, etc.
  ---
  ```

The index is the only part loaded wholesale into context. The topic files are
pulled on demand. So the index is where the budget pressure lives.

## The Budget

`MEMORY.md` must stay **under its load budget (~24KB)**. Beyond it the loader
only *partially* loads the index — entries past the cutoff silently never reach
the session, and recall degrades. (This happened: the index grew to ~38KB,
loaded partially, and was trimmed back to ~24KB by shortening over-long hooks.)

- The **index** holds hooks, not detail. Each line is **≤ ~200 characters**.
- **Verbose detail belongs in the topic file**, never the index. The index line
  exists only to make an agent remember the topic file is worth opening.

## Owner & Cadence

**Steffon** owns memory maintenance (QA/Infra lane), the same lane that owns
test pruning. Run it as a recurring **`chore`** task on a **monthly** cadence —
or any time `MEMORY.md` exceeds budget, whichever comes first.

## Triggers

- `MEMORY.md` over its load budget (the hard trigger).
- Stale or superseded entries piling up (a fact changed, a thing shipped, an
  approach was abandoned).
- Broken links — an index line points at a topic file that no longer exists.
- Duplicate or overlapping memories covering the same lesson.

## Procedure

1. **Size check.** Measure the index against the budget:

   ```bash
   wc -c ~/.claude/projects/-Users-alex-projects/memory/MEMORY.md
   ```

   Under ~24,000 bytes is healthy. Over it, the index is being truncated on
   load — fix it this pass.

2. **Trim over-long hooks.** For any index line past ~200 characters, cut it to
   a tight one-liner. The detail does not disappear — it already lives in the
   topic file. Shortening hooks is the cheapest way back under budget and
   loses nothing.

3. **Prune stale / superseded memories.** A memory is safe to delete only when
   it is wrong or superseded **and** the durable fact is captured elsewhere. If
   the fact still matters and belongs in a repo, **relocate it first** to the
   owning repo doc (per
   [`docs-maintenance.md`](docs-maintenance.md)), then delete **both** the topic
   file **and** its index line. Never orphan one without the other.

4. **Consolidate duplicates.** When two memories cover the same lesson, merge
   them into the better topic file, delete the weaker one, and leave a single
   index line.

5. **Verify integrity.** Confirm the index and topic files are 1:1 — every
   index link resolves to a real file, and every topic file has exactly one
   index line:

   ```bash
   cd ~/.claude/projects/-Users-alex-projects/memory/
   # Broken links: index lines pointing at a missing topic file.
   grep -oE '\]\(([a-zA-Z0-9_./-]+\.md)\)' MEMORY.md | sed -E 's/^\]\(|\)$//g' \
     | while read -r f; do [ -f "$f" ] || echo "BROKEN LINK: $f"; done
   # Orphan files: topic files with no index line.
   for f in *.md; do [ "$f" = "MEMORY.md" ] && continue; \
     grep -q "($f)" MEMORY.md || echo "ORPHAN FILE: $f"; done
   ```

   Both loops should print nothing.

6. **Never memorialize what the repo already records.** If a fact already lives
   in `CLAUDE.md`, `AGENTS.md`, an active doc, or git history, it does not belong
   in the memory store — relocate anything worth keeping and drop the memory. The
   store is for cross-session lessons the repo does *not* capture, not a second
   copy of the docs.

## KPIs

- `MEMORY.md` stays **under budget** and loads in full (the headline metric).
- **Zero broken links** — every index link resolves.
- **1:1 index ↔ topic file** — no orphan files, no index lines without a file.
- **Stale-entry count trending down** month over month.

## Avoid

- Putting detail in the index — that is what blows the budget.
- Deleting a topic file but leaving its index line (or vice versa).
- Memorializing facts the repo already owns.
- Letting the index drift over budget between monthly passes.
