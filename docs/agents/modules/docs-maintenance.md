# Docs Maintenance

Docs are part of the product surface for agents. When code changes behavior, update the document that a future session would read first.

## Source Of Truth

- Cross-repo agent workflow: `mcritchie-studio/docs/agents/`
- Ecosystem map and recovery: `mcritchie-studio/docs/ECOSYSTEM.md`, `docs/agents/system/house-burn-down.md`
- Shared email operations: `mcritchie-studio/docs/agents/modules/email-operations.md`
- App-specific behavior: the owning repo's README, runbook, and topic docs
- Audit process: `mcritchie-studio/docs/agents/modules/audit-playbook.md`
- Historical audits and prompts: archive or ledger once their live facts are promoted

## Editing The Entry Docs (`AGENTS.md` / `CLAUDE.md`)

The projects-root `/Users/alex/projects/AGENTS.md` and `CLAUDE.md` are
**generated**. `bin/install-agent-docs` copies `docs/agents/index.md` →
`AGENTS.md` and `docs/agents/claude.md` → `CLAUDE.md` (plus the user-global
skills). Edit the sources in this repo; never edit the generated roots — an edit
there is silently reverted by the next install.

**Nobody hand-runs the installer.** The install is an owned pipeline step:
`sync_agent_docs` in `bin/release.rb`, which `bin/release ship` runs after every
production ship (Steffon, G4 Ship) from the hub's ship workspace — the tree
pinned at the SHA that just shipped. It runs unconditionally, is idempotent, is
non-fatal by construction, and heals prior drift.

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
`~/.codex/hooks.json`, sets the Codex TUI status line, and appends the Ruby PATH
block to `~/.zprofile`. Every one of those targets is **global and shared** —
the operator's live login profile and editor settings included.

`test/docs/executable_docs_installer_test.rb` holds the set to the two above. It
sweeps the docs an agent **executes** — every registered SOP in the invocation
table, the `maintenance/kickoff-*.md` briefs, and everything under
`docs/agents/skills/` — treating *any* mention of the installer as a hit that
owes an explicit exemption. Descriptive docs under `system/` and `modules/` are
**not swept**: they name the installer legitimately and constantly (this file
does), so the any-mention rule would drown there. That limit is deliberate, and
it is no longer a blanket amnesty for design docs — see the scope guard next.

**Where the command is printed, the scope is printed with it.**
`test/docs/installer_command_scope_test.rb` sweeps **all** of `docs/agents/**`,
`system/` and `modules/` included, and asks a different question: not "is the
installer mentioned" but "is the reader being handed a command to run". Every
fenced `bin/agent-runtime install` / `bin/install-agent-docs` command line must
carry the bringup scope — on the line itself, or in the prose that introduces
the block. Three sites qualify today, and the predicate draws **zero** false
positives across 123 live docs, because a copyable command line is a different
object from a prose mention. It pairs that with an imperative-mood directive
sweep and a per-site pin on
[`../system/bootstrap.md`](../system/bootstrap.md), whose unscoped invitation to
run the installer by hand is the defect it was written for.

**Its limit, stated so nobody over-trusts it in turn:** it sees command
*presentations* and the imperative mood — not every sentence that could talk a
reader into a run. A third-person rationale is still caught only where it names
the wrong source tree (`test/docs/ship_docs_sync_docs_test.rb`). Three guards,
three predicates: any mention in an **executed** doc, the wrong **source tree**
anywhere, and an **unscoped command** anywhere.

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

**Cite the SEAM, not the line.** A line number is true only at the SHA it was
written against, and nothing re-reads one: every commit to a cited file silently
rots every citation below its edit point. A rotted citation does not look rotted —
it reads exactly like the truth and routes the next reader to whatever happens to
sit at that offset today.

That is measured, not feared. On 2026-09-14, on `accepted` at **b811daae** — the commit
before the guard below landed — eight `bin/release.rb:<line>` citations were spot-checked
after one ordinary commit shifted that file, and **all eight were already pointing at
unrelated lines**, one at a blank line. Two more sat in the same table cell of the
QA-release SOP as the sentence announcing this very discipline.

Do not try to re-derive those ten on today's tree. The same change converted every one of
them to a seam, so the population they were drawn from is gone; the SHA is where they are
still visible, and it is named here for exactly that reason. The number that IS live is
the ratchet's — run `bin/rails test test/docs/citation_resolution_guard_test.rb` and lane
3 censuses the tree in front of you.

| Form | Write it as | Rots? | Checked by |
|------|-------------|-------|------------|
| **Seam** (preferred) | `bin/release.rb#commit_gem_version!` | No | lane 2 — the file must DEFINE that symbol |
| **Prose seam** | "in `commit_gem_version!` — at its `rewrite_version` refusal" | No | review |
| **Anchored line** (when the line really is the unit) | `bin/fast-check:209#"wrong_root = TaskTree.refusal"` | **Loudly** — lane 4 reds and names the line it slid to | lanes 1 + 4 — substantive AND carrying its anchor |
| **Bare line** (legacy — lane 5 is closing it) | the same pointer without the `#"…"` | **Silently** | lane 1 only, and only when the rot lands on a blank line or an `end` |

The rules, in order:

1. **Name a definition the reader can search for** — a method, a constant, a class,
   a YAML key. `path#symbol` is the written form; the enclosing definition is the
   right seam for a line of code inside one.
2. **Spend a `path:line` only where the line itself is the unit** — top-level script
   code with no enclosing definition is the honest case. Say what is ON the line, so
   a reader who lands somewhere else knows immediately.
2a. **Say it IN the citation, not beside it** — `path:line#"what is on it"`. Until
   2026-09-22 this house already wrote that anchor, in prose, next to almost every line
   citation it had; nothing read it, so it could not stop the pointer drifting off the
   thing it described. Written inside the citation it is CHECKED: lane 4 opens the file
   on every run, and when the span no longer carries the anchor it reds and names the
   line that does. Three spellings — `#"a quoted phrase"`, `` #`a backticked one` ``, or
   a bare `#token` for a Ruby name. **Pick an anchor that occurs once.**
   `#"--gate-role review"` sits on eleven lines of `bin/dor-check` and pins loosely;
   `#"reviewers run --gate-role review"` sits on one.
2b. **When lane 4 reds, fix the NUMBER.** Never edit the anchor to match whatever is
   at the line now — that silences the lane and leaves the citation pointing exactly
   where it should not. The failure has already re-derived the right line for you. An
   anchor that is NOWHERE in the file means something else again: you are citing the
   wrong file, or the passage is gone and the sentence now claims nothing.
2c. **A range is checked at BOTH ends.** A `path:a-b` whose LAST line is a bare `end`
   has slid off its subject — the range was cut to fit a passage, so a block terminator
   at the bottom of it means the passage has moved. Do not trim the range by one to go
   green; re-derive where the passage went.
3. **Never renumber from a stale start.** Re-derive the number on your own tree, or
   convert the citation to a seam. Renumbering is its own error, and the next commit
   re-rots it.
4. **A Ruby backtrace frame is evidence, not a citation.** `foo.rb:118:in '...'` in a
   fixture is what the interpreter said at the SHA it crashed on. Leave it alone.
5. **A second anchor is a second citation, and it needs its own colon.** `<file>:224 + :232`
   and `<file>:631, :1139` are TWO pointers each — the continuation inherits the path of the
   citation it follows, and both halves rot independently. The guard resolves and counts
   both, so a continuation buys nothing: it costs the same ratchet toll as spelling the path
   out twice. Until 2026-09-14 it cost nothing because no lane could see it, which is how
   three of them came to be live in this repo at once — two of them pointing at the wrong
   line. **Write the colon.** A bare `<file>:229,231` is the same string as a thousands
   separator, so the guard refuses to read it either way: it will not count your second
   anchor, and it will not mint one out of somebody's `<file>:8,370`. Spell it `:229, :231`.

`test/docs/citation_resolution_guard_test.rb` is the teeth, in five lanes. Four of them
key on **resolution** — they open the cited file and look — never on the wording around
the citation, so no rephrasing gets past them. Lane 4 is the one that reads CONTENT, and
it does so only where an author DECLARED an anchor, which is why it has no false
positives to trade for its reach.

Read the header's limits before trusting a green run to mean more than it does. Two
matter most. Limit D: the ratchets are toll booths kept monotonic by REVIEW, not by a
check. And lane 4's own: it catches **rot** — a citation whose file moved under it —
never a citation that was **wrong when it was written**, because an author reading the
wrong line copies the anchor off that same wrong line. A green lane 4 says the pointer
still lands where its author put it. It does not say the sentence is true.

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
