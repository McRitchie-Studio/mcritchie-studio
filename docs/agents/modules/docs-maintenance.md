# Docs Maintenance

Docs are part of the product surface for agents. When code changes behavior, update the document that a future session would read first.

## Source Of Truth

- Cross-repo agent workflow: `mcritchie-studio/docs/agents/`
- Ecosystem map and recovery: `mcritchie-studio/docs/ECOSYSTEM.md`, `docs/agents/system/house-burn-down.md`
- Shared email operations: `mcritchie-studio/docs/agents/modules/email-operations.md`
- App-specific behavior: the owning repo's README, runbook, and topic docs
- Audit process, and the rules for correcting a claim in prose: `mcritchie-studio/docs/agents/modules/audit-playbook.md`
- Historical audits and prompts: archive or ledger once their live facts are promoted

## Editing The Entry Docs (`AGENTS.md` / `CLAUDE.md`)

The projects-root `/Users/alex/projects/AGENTS.md` and `CLAUDE.md` are
**generated**. `bin/install-agent-docs` copies `docs/agents/index.md` →
`AGENTS.md` and `docs/agents/claude.md` → `CLAUDE.md` (plus the user-global
skills). Edit the sources in this repo; never edit the generated roots — an edit
there is silently reverted by the next install.

**Nobody hand-runs the installer.** The install is an owned pipeline step:
`bin/release.rb#sync_agent_docs`, which `bin/release ship` runs after every
production ship (Steffon, G4 Ship); that method picks the tree it installs from.
It runs unconditionally, is idempotent, is non-fatal, and heals prior drift.

So `installed docs/skills drift` between a docs merge and the next production
ship is an **expected state, not a chore anyone owes**. It closes itself on the
next ship. Acting on it is wrong from either tree: a run from a feature worktree
publishes unshipped mid-branch text to every session on the machine, and a run
from a primary republishes a `main` that can sit a release behind what shipped
(the ship's restore is best-effort and refuses a primary holding a live
session's work). Such a run does not CLOSE the drift, it MOVES it — because
`bin/session-preflight` measures the shared roots against ITS OWN checkout's
sources, publishing from one tree clears that tree's report and turns every
other session's report red. Verify with `bin/install-agent-docs check`
(read-only) at any time.

Two runs stay legitimate, and neither is a response to a drift report:
`bin/agent-runtime install` at **bringup** — a machine with no roots installed,
whether that is a full fresh-machine rebuild
([`../system/house-burn-down.md`](../system/house-burn-down.md) step 5b) or a
single app cloned onto a bare machine
([`../system/bootstrap.md`](../system/bootstrap.md)) — and the by-hand fallback
`bin/release ship` prints when its own `sync_agent_docs` step fails.

**Bringup is the scope, and single-app bringup is inside it.** Exemption 1 used
to read "fresh-machine", which left the one-app case arguing about whether it
counted; it does. The test is the MACHINE, not the app count: no roots installed
and no ship to wait for. That is the whole of it — an app cloned onto a machine
that already has roots is not bringup, and neither is a drift report.

**Exactly those two — the list is closed.** Xan's `share-insights` act used to
run the installer as a third; it no longer does, and must not again. Its output
is the tracked lessons doc [`../shared/insights.md`](../shared/insights.md),
which this installer has never published, and a fresh session reads insights from
the board (`bin/session-insights` GETs `/api/v1/insights`), not from that file.
So the step distributed nothing the act produced.

**What the installer actually writes** — worth stating, because "it only copies
two docs" is how a hand-run gets talked into. `install` publishes the two entry
docs (`index.md` → `AGENTS.md`, `claude.md` → `CLAUDE.md`), mirrors
`docs/agents/skills/**` into `~/.claude/skills` and `~/.codex/skills` and
`rm -rf`s retired ones, rewrites the managed hooks in `~/.claude/settings.json`
(PostToolUse capture, SessionStart mascot + insights, SessionEnd close-open) and
their Codex equivalents in `/etc/codex/requirements.toml` or
`~/.codex/hooks.json`, each command at the fixed path
`/Users/alex/projects/.agents/bin`, points the github.com credential helper line
in `~/.gitconfig` at the same `bin/`, sets the Codex TUI status line, and appends
the Ruby PATH block to `~/.zprofile`. Every one of those targets is **global and
shared** — the operator's live login profile, git config and editor settings
included.

**A feature desk cannot publish.** `bin/install-agent-docs install` refuses, before
it writes anything, when it runs from a desk under `.worktrees/` other than the
ship's own workspace and `PROJECTS_DIR` is not pinned to a sandbox, and it prints
this rule as its answer. So a doc that names the installer cannot talk anyone into
the worktree publish; `check` still runs from any desk, read-only.
`test/commands/install_agent_docs_desk_refusal_test.rb` holds the refusal. A run
from a primary is not refused, because bringup runs there; the closed list above
is what keeps it to bringup.

## What A Doc Guard Scans

**A doc guard's population is decided once, in `test/support/stated_prose.rb`.** Do
not give a new guard a glob of its own.

Two guards shipped on 2026-09-22 each globbing a DIRECTORY, and both carried the same
hole: a guard that scans `docs/**` structurally cannot see a site making its claim
OUTSIDE `docs/`. Both holes were live. The preview guard missed a bare invocation
sitting in the feature's own service; the turf-vault lane guard missed three stale
lane counts in `config/release_repos.yml` — the file where that lane is DECLARED —
and another in `bin/fast-check`, the script that runs it. The most authoritative
place to state a claim is usually not a doc.

`StatedProse.sources(Rails.root)` is that population: **markdown anywhere**, plus the
**comment bodies** of `config/`, `app/`, `lib/` and `bin/`. In a non-markdown file it
blanks every line that is not a comment, so code is never read as a claim and a cited
line number still points where a reader can open it.

**Why one population and not two wider globs.** A glob decides what every future
author is measured against. Two builders answering that question separately produce
two globs and two exemption conventions — which is how a repo ends up with two
authorities disagreeing. Any new guard over stated prose reads this population.

**The exemptions are load-bearing, not tidiness:** frozen records (an explicit
`ARCHIVE-ONLY` banner, never the task stage word `archived`), `/archive/` and
`/audits/` as path SEGMENTS rather than prefixes, vendored trees, `/.worktrees/`
(every desk is a full checkout nested inside the primary, so a naive sweep reports
other tasks' drafts), and `test/` (a guard cannot scan its own verbatim fixtures).

**Widening owes a NEGATIVE control.** A guard that reds on correct text is worse than
a guard with a blind spot, because it trains authors to route around it. Widening
these two surfaced one immediately: `bin/fast-check` says a cert "died on
`bin/rubocop` one lane later" — a time idiom, inside a turf-vault paragraph, correct
as written, and read as a lane count by a pattern that accepted a bare singular. Both
guards now carry accepted-prose fixtures beside their regression fixtures, and that
sentence is one of them.

## Citing Code From Prose

**Cite the seam, never the line.** A line number is true only at the SHA it was
written against: every commit to a cited file shifts every line below its edit, and
a shifted citation reads exactly like the truth while it routes the reader to
whatever sits at that offset now. A seam names a definition, so no edit elsewhere in
the file can move it.

| Form | Write it as | Checked by |
|------|-------------|------------|
| **Seam** | `bin/release.rb#commit_gem_version!` | the citation guard: the file must DEFINE that symbol |
| **Prose seam** | "in `commit_gem_version!`, at its `rewrite_version` refusal" | review |

The rules:

1. **Name a definition the reader can search for**: a method, a constant, a class, a
   shell function, a YAML key, or a top-level variable. `path#symbol` is the written
   form; for a line inside a method, the enclosing method is the seam.
2. **No `path:line`.** Top-level script code with no enclosing definition is cited by
   the nearest variable or constant it uses, or as a prose seam that names what is on
   the line.
3. **A Ruby backtrace frame is evidence, not a citation.** `foo.rb:118:in '...'` in a
   fixture is what the interpreter said at the SHA it crashed on. Leave it alone.

`test/docs/citation_resolution_guard_test.rb` holds the rule. It counts the
`path:line` citations into this repo and requires zero, and it resolves every
`path#symbol` against the file it names. It reads no prose, so no rephrasing gets
past it. Its limit: a seam resolves when the symbol is defined in that file, never
proving it is the landmark the sentence means.

## Drift Review

When finishing a meaningful feature:

1. Search docs for the changed route, env var, port, provider, model, or workflow.
2. Update the canonical doc.
3. While editing active docs, fix nearby ambiguous owner/orchestrator language:
   use **Alex** for Alexander Ray McRitchie, the owner/operator, and **Xan**
   for the orchestrator agent.
4. If an old doc is superseded but not safe to delete yet, add it to [`../maintenance/delete-later.md`](../maintenance/delete-later.md).
5. Prefer deleting stale docs over preserving contradictory context.

## Closeout Checklist

Use this before handing a feature back:

1. Check `git status --short --branch` in every repo you touched.
2. Run the narrowest meaningful tests or smoke checks yourself.
3. Run `bin/agent-runtime check` from McRitchie Studio if
   `docs/agents/index.md`, generated root guidance, or a user-global skill under
   `docs/agents/skills/` changed.
4. Run `bin/register-satellite --list` after app registry changes.
5. Run `bin/agent-worktree doctor` after worktree lifecycle changes.
6. Return an inspectable result: local URL, local inbox URL, screenshot, test
   summary, commit SHA, or concrete blocker.

## Session Retrospectives

After a long or high-leverage session, add a short retrospective under
`docs/agents/audits/` when the conversation uncovered reusable operational
lessons. Retrospectives should capture:

- What worked.
- What caused friction.
- Which docs or tools were updated.
- What future agents should do differently.

Keep retrospectives distinct from closeout audits. A closeout says what the
system state is now; a retrospective explains what the team learned while
getting there.

## Recurring Drift Maintenance

Do this weekly, or after several agent sessions:

1. Review [`../maintenance/delete-later.md`](../maintenance/delete-later.md).
2. Check for visible sibling worktrees and hidden `.worktrees/` salvage dirs.
3. Re-check root stray files under `/Users/alex/projects`.
4. Search for old ports, domains, provider names, and LLM-specific references
   in active docs.
5. Promote durable lessons from local memory or chat into McRitchie Studio docs.

Keep historical audits available when they still explain why a decision was
made, but add an archive banner or ledger row when they could be mistaken for
current procedure.

## Machine-Local Claude Context

Old Claude memory under `/Users/alex/.claude/` can contain useful history, but it is not durable source of truth. Promote durable lessons into `mcritchie-studio/docs/agents/` or the owning repo docs.

Imported lessons from the first cleanup pass:

- Give Alex something inspectable, usually a local URL, screenshot, or test result summary.
- Leave documentation cleaner than you found it.
- Use targeted 1Password reads; never print secrets.
- Treat old `3001` and `turf.mcritchie.studio` references as stale unless the
  file is explicitly historical. `turf.mcritchie.studio` is not merely old, it
  is dead — it answers HTTP 000 — while Turf Monster serves at
  `turfmonster.media`. See `docs/agents/modules/deployment.md` § Retired Host.
- Route backend failures through `ErrorLog` when the app supports it.
- Validate before irreversible external effects.
- Keep reusable local maintenance scripts in a tracked repo, preferably McRitchie Studio, so a fresh machine can rebuild them.

## Avoid

- Duplicating volatile test counts.
- Encoding secrets directly in docs.
- Adding LLM-specific files when an agent-neutral module will do.
- Leaving old audit prompts next to active runbooks without an archive marker.
