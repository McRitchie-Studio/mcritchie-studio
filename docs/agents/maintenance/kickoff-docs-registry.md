# Kickoff — Every live doc is registered, or it isn't live

Paste the section below the rule into a fresh session started from
`/Users/alex/projects`. The tables here are the working payload.

---

## The problem

`docs/agents/modules/` and `docs/agents/system/` hold **67** documents. **32 of
them are named nowhere in the Start Here table** in `docs/agents/index.md` — the
map that tells an agent which doc answers which need. They can only be found by
grepping for a lucky keyword.

An unfindable doc gets rewritten from scratch by the next agent who needs it.
That is the actual engine of documentation bloat: not files that are too long,
but two files on the same subject that slowly disagree.

The clearest example: `docs/agents/modules/gates/dor.md` is **358 lines**, sits
in the gates directory beside `g1-cert.md` through `g4-ship.md`, and Start Here
lists **g1 through g4 but not dor**. A gate document, in the gates folder,
invisible to the index.

## You already built the mechanism — for SOPs only

`test/docs/sop_registry_docs_test.rb` enforces exactly the property we want:

```ruby
test "every registered SOP path exists on disk"
test "every SOP file on disk is registered by name in docs/agents/index.md"
test "the two registry tables in index.md name the same set of SOP files"
test "every invocation the Claude adapter names is a real registered invocation"
```

**An unregistered SOP cannot merge.** That is why the SOP tree is clean while
`modules/` and `system/` drifted to 32 unindexed files. The job is to extend a
proven pattern, not to invent a convention.

## The organizing principle

Mr. McRitchie's rule, and it should decide every judgment call here:

> All important documentation should always be working its way toward a specific
> SOP, for standardization.

A doc that is not travelling toward a registered SOP or module is either not
important, or it is important and orphaned. Both need resolving. There is no
third category, and "leave it where it is" is not an outcome.

## Every doc gets exactly one of three outcomes

| Outcome | When | Result |
|---|---|---|
| **Index** | It is live, standalone, and someone needs to find it | Added to the Start Here table with a `Need` phrase |
| **Fold** | Its content belongs inside a registered module or SOP | Merged there, file deleted |
| **Archive** | It is a frozen snapshot or superseded | `git mv` to `docs/agents/archive/` |

## Two sessions are clearing 13 of the 32 — do not duplicate their work

| Overlap | Count | Owner |
|---|---|---|
| Frozen audits (`ecosystem-audit`, `md-audit`, `opsec-audit`, `prelaunch-*` ×4, `multi-auth-identity-design`, `squads-migration-prep`) | 9 files, ~3,156 lines | The **archive sweep** in `kickoff-log-rotation.md` |
| Stale docs (`activity-logging`, `comms`, `nightly-sync`, `user`) | 4 files, 174 lines | The **Row 2** hub task |

Check whether those have landed before you start. If they have not, either wait
or scope yourself to the 19 below and let the test tolerate the rest until they
clear — but say which you chose.

## Your actual payload — 19 live, unindexed docs (~2,937 lines)

| File | Lines |
|---|---|
| `system/atomic-capture-hook.md` | 466 |
| `modules/gates/dor.md` | 358 |
| `system/devops-shift-lease.md` | 280 |
| `system/secrets-rotation.md` | 260 |
| `system/squads-upgrade-authority-migration.md` | 196 |
| `system/news-pipeline.md` | 180 |
| `system/turf-vault-audit-rfp.md` | 154 |
| `system/turf-vault-mainnet-rollout.md` | 154 |
| `modules/codex-thread-title-request.md` | 135 |
| `system/new-app-scaffolder-spec.md` | 132 |
| `system/exclusive-lanes.md` | 111 |
| `system/mission.md` | 105 |
| `system/git-protocol.md` | 100 |
| `system/bootstrap.md` | 73 |
| `system/sizing-rubric.md` | 58 |
| `system/architecture.md` | 47 |
| `system/memory.md` | 47 |
| `modules/review-comment-taxonomy.md` | 43 |
| `system/coding-standards.md` | 38 |

Several are plainly load-bearing and simply never got indexed —
`atomic-capture-hook.md` documents the narration system every session uses, and
`gates/dor.md` documents a gate. Those want **Index**. Others are small enough
that they likely want **Fold**. Read each; do not batch-decide.

## Build the guard

Extend `test/docs/` with the same shape as the SOP registry test, so this cannot
recur:

- Every `.md` under `modules/` and `system/` is named in the Start Here table.
- Every path the Start Here table names exists on disk.
- Anything exempt is exempt **by an explicit allowlist in the test**, not by
  being forgotten.

Assert the property — a file's presence in the table — not the presence of a
string somewhere in the repo. A guard that passes because a filename happens to
appear in a code comment is a guard that lies.

Consider whether `docs/agents/archive/` should be excluded from the guard
entirely. It should: archived docs are frozen and unindexed **by definition**,
and requiring them in Start Here would defeat the archive sweep.

## Definition of done

- Every doc in `modules/` and `system/` is indexed, folded, or archived — no file
  left in a fourth state.
- The Start Here table names a real path for every row, and every live doc has a
  row.
- A new `test/docs/` guard fails when a doc is added without an index entry.
- The guard exempts `archive/` and carries an explicit allowlist for anything
  else, with a comment saying why each exemption exists.
- `bin/install-agent-docs` still regenerates `/Users/alex/projects/AGENTS.md`
  cleanly, and the existing `sop_registry_docs_test.rb` still passes.

## Routing

This is one **mcritchie-studio** task, shape `library` or `backend` (no UI). It
touches `docs/agents/**`, `docs/agents/index.md`, and `test/docs/`. The fast lane
works — this is a normal app repo, not the gem.

Because `docs/agents/index.md` generates the root `AGENTS.md`, run
`bin/install-agent-docs` after the edits and confirm the generated file matches.
