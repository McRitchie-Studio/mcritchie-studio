# Shared Agent Memory — retired

This hand-edited file drifted stale (it once taught retired facts — a fixed agent
count, "immutable random-hex" task slugs, an unauthenticated API). It is **no longer
a source of truth.** Its two jobs now live in canonical places:

- **Distilled lessons** — the curated agent lessons are now the **Insight Bank**
  (`ActionGrade.banked`), and the tracked doc is **generated** from it:
  [`docs/agents/shared/insights.md`](insights.md). Curate lessons into the bank with
  `bin/agent-activity grade <activity-id> --disposition good|not --slug "…" --bank`; regenerate
  the doc with `bin/rails insights:doc`. A fresh session **will** load them via the
  planned `bin/session-insights` SessionStart loader (once it lands). See
  [`../system/memory.md`](../system/memory.md).

- **Operational reference** — accounts / 1Password → `../modules/credentials.md`
  and `../modules/credential-inventory.md`; conventions → `../system/coding-standards.md`;
  ecosystem status → `../ECOSYSTEM.md`.

Do not add lessons here — they will be missed. Bank them instead.
