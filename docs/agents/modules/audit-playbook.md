# Audit Playbook

Use this when Alex asks for an ecosystem, repo, architecture, docs,
security, or readiness audit.

## Operating Rules

1. Start at `/Users/alex/projects/AGENTS.md`.
2. Read the current entrypoints before old audits:
   - `mcritchie-studio/docs/ECOSYSTEM.md`
   - app README/topic docs for the repo under review
   - relevant current modules in `mcritchie-studio/docs/agents/modules/`
3. Treat dated audits, prompt artifacts, and `CLAUDE.md` files as historical
   context only unless a current doc points to them as active procedure.
4. During a pure audit phase, stay read-only until Alex approves changes.
5. When Alex asks to execute cleanup, update the owning current doc
   instead of adding a new one-off note.

## Audit Shape

For a broad audit:

1. Establish scope: repos, workflows, risk surfaces, and whether code changes
   are allowed.
2. Read current docs first, then verify claims against code.
3. Identify contradictions, stale procedures, missing tests, unsafe defaults,
   and places future agents would read the wrong file first.
4. Ask only materially shaping questions after enough context is gathered.
5. Save durable audit output under `mcritchie-studio/docs/agents/audits/`.

For a focused app/security audit, keep findings grounded in `file:line`
references, rank by severity, and separate:

- confirmed defects;
- residual risk or design debt;
- documentation drift;
- test gaps;
- external approvals or provider-side blockers.

## Deliverable

Use this structure unless Alex asks for something narrower:

```text
# <Audit Name>

Date:
Scope:
Mode:

## Executive Summary

## Verified Current State

## Findings

## Recommended Work

## Residual Risk

## Follow-Up Ledger
```

If cleanup work is performed, update `docs/agents/maintenance/delete-later.md`
for superseded files and update `docs/agents/audits/final-closeout-*.md` when
the closeout state changes.

## Do Not

- Do not treat old prompt files as reusable instructions.
- Do not copy stale ports, program IDs, sender domains, or credential values
  from historical docs.
- Do not ask Alex to run terminal commands for audit proof the agent can
  gather directly.
- Do not mark an external/provider blocker complete until it is actually proven.

## What A Search Proves

A hit, a miss and a clean scan each prove less than they appear to. Audits,
reviews and briefs all lean on them, so hold each to its narrow meaning.

- **A miss proves a string is absent, nothing more.** A fix often lands in other
  words, or moves into a command that now owns the job; reachability travels
  through loaders, globs, `db:seed`, a rake `invoke`, or a job enqueued by name.
  Write "the name does not appear in X", never "X does not run it". To claim code
  is unreached, trace the call graph or instrument a run.
- **Prove the file was in the search set.** A grep over a tree that lacks the
  file looks exactly like a clean result. `ls` it or `git cat-file -e <ref>:<path>`,
  `git fetch` first, and read merged state with `git show origin/accepted:<path>`
  rather than a local primary. A cross-repo claim needs a cross-repo search.
- **Prove the scanner can see a positive.** Point it at a term you know is there
  before trusting its silence. Known blind instruments: `git grep -E` has no `\b`
  and answers a clean zero (use `-P`); `--include='*.rb'` skips the extensionless
  scripts in `bin/`; `grep -o` or `-h` drops filenames, so a later path filter
  does nothing; a `grep -v` pattern can match your own scratch path; a command
  that fails upstream of a pipe prints nothing and greps clean.
- **A window ends silently.** `head`, a row cap and a paged listing never say
  "there was more". Print the count first (`wc -l`, `--json` and a length,
  `gh ... --paginate`) and compare it with what you displayed. A universal claim
  ("every", "none") needs an exhaustive query, never a generous `--limit`.
- **A failed enumeration is unverifiable, not empty.** A lookup that returns `[]`
  on error must never be read as "none exist".
- **The hit list is a queue.** Open every file a grep lists; the files that fail
  are the ones whose names did not advertise their contents.
- **A hit is not a verdict.** Read its enclosing heading (a multi-environment doc
  repeats each field, and the first match is rarely the one in question), its
  whole function (a matched assignment may be the fallback, or may pick the
  script rather than the tree), and the paragraph above a quoted line (long
  comments narrate the defect they closed, in the past tense).
- **Match the field, not the line.** A short numeric token over structured output
  also matches hashes and payloads: split the line and test the column
  (`awk '$1=="120000"'`). A polymorphic id means nothing without its `*_type`.
- **Search for the proposition.** Grepping a slug or one phrasing finds the files
  that discuss a claim and misses those that restate it. Match the concept with
  an alternation over `git ls-files`, unfiltered, then discard by reading.
  Spawn prompts, error strings and `--help` text are prose too.
- **Count a pattern's matches.** A pattern with several hits can be satisfied by
  one that is not the rule; prove each regex alternative matches a real input.
- **In an `a || b || c` guard, find the first member that returns.** Every member
  after it is unreached, which is not the same as dead.

## What A Number Proves

- **A quantifier is a measurement.** *Every, all, none, only, both* and any number
  in prose owe a command. Run the count, or weaken the sentence to what you did
  check. If a parameterized test backs "by construction", check that its sweep
  crosses zero, the sign change, the empty set and nil.
- **Name the construction.** State how the input was built and what was stripped,
  wrapped or truncated; a normalized copy is a different input under the same
  name. Print `n` beside every derived figure: a near match at a different `n`
  is a construction error that looks like success.
- **Take a ratio from one run**, with its parameters named. When a sweep widens,
  re-run all of it. Evaluate any example coordinate rather than reasoning that
  it qualifies.
- **Derive on the tree in front of you, when you write the number.** Never copy a
  count from a review, a sibling branch or an earlier run. Some cross-branch
  figures are phases of the release cycle (`main` against `release`): publish
  the refs and the moment, or the invariant instead. When re-deriving a set,
  the figures that do not move are the control that validates the method.
- **A count is a level, not a delta.** Grade a write by something that must
  change when the work is real: distinct values, a min/max spread, a
  `finished_at` after this run started. A count also cannot see a permutation;
  when slugs are keys, assert the mapping.
- **A number with no command beside it is suspect.** Grep the test suite for the
  literal; a fixture stub is a common source. When samples vary, write the order
  of magnitude rather than one sample.
- **A hand check measures the hand's client.** A `curl` that answers 200 proves
  nothing for `Net::HTTP` if the host keys on User-Agent. Check with the client
  that will make the call.
- **Forecast with the read path the feature will use**, not the table it seems
  to come from.
- **Sampling twice must name the comparison.** Decide before the second read what
  would change your mind; the delta often carries the answer. A source that could
  not have said no is not a vote, so agreement counts only between independent
  sources.
- **Before believing a failure measurement, confirm the failing code ran.** An
  empty fixture, a missing record or a load error upstream produces a failure that
  says nothing about the code under test.

## What A Claim Owes

- **Run the cell that could falsify it.** Before writing "X does not do Y", ask
  which experiment would show that it does, and run that one. Consistent results
  from cells that cannot reach the mechanism are silence, not evidence. Prefer
  naming the trigger over denying a source.
- **Which input reaches which branch is settled by a run**, not by reading the
  branch. Reviewers are as prone to this as authors.
- **Check the claim, not a proxy.** State the property that matters ("the money
  has moved") and look where it would be false. An observation two states
  produce alike is evidence for neither; find the field that discriminates.
- **A remedy is a causal claim.** Before printing operator advice, test that each
  named cause can produce the failure. When handed a diagnosis and a fix, apply
  the fix and re-run the failing case; a fix that does not move the measurement
  falsifies the mechanism. Never pin a diagnosis's wording in a test.
- **A right conclusion can rest on a false reason.** Test the premise separately,
  and check that a stated cause occurred (`git log` the file, diff the trees).
  Keep the conclusion and replace the reason.
- **Hold a disconfirmation to the claim's standard.** State the exact key and
  scope searched, then vary both; two empty searches with one wrong key are one
  search. A true mechanism can carry an unevidenced instance, and the reverse.
- **An analogy is its own claim.** When a report says "this is just like our X",
  ask which party in the source example maps to us before importing its
  conclusion.
- **A snapshot speaks only for its date.** Evidence older than a claim cannot
  refute it; say what it shows at its date and what would settle the rest.
- **A conditional caveat is a conjunction.** Before writing "therefore" over
  "once A and B", say which run discharged each conjunct; otherwise narrow the
  caveat rather than retiring it.
- **A real number can carry the wrong cause.** Before attributing load, a timeout
  or a failure, look at what is actually there (`ps` sorted by CPU, the log).
  An agent volunteering blame is not evidence.

## Correcting A Claim

A corrective diff is where false claims enter. The search rules above say what a
hit proves; these are the writing rules.

- **Find every site before changing one** — `bin/`, `lib/`, `test/` assertion
  messages, `config/`, generated roots, and the rest of the file you are editing.
  A partial pass leaves two authoritative truths. Your new explanatory comment
  means the sweep is unfinished, not done.
- **Name each hit's subject.** The same words can be true elsewhere; report
  corrected and verified-true sites separately.
- **The replacement sentence is a new claim.** Prove it like code.
- **Tense follows `accepted`.** Work in an open PR takes the future tense and its
  task slug. A link to a file another PR adds goes in backticks: live
  `docs/agents` links must be servable (`test/integration/doc_reference_servability_test.rb`),
  so a link outside `docs/agents` is always a backticked path.
- **Prose that says automation runs code names the caller** — the `Procfile`,
  `config/recurring.yml`, a `post_deploy_cmd`, a workflow step.
- **After an operator-driven rewrite or a scripted patch, re-read** the touched
  comments end to end, and grep for the value you moved away from. Record a
  rejected approach as rejected.
- **A false doc often copies a false comment.** Grep the code for the claim's
  wording, and file the comment too.
- **A global proof stamp vouches for every row**; refreshing it re-asserts rows
  the new run never exercised, so qualify them in place.
- **History is read at its SHA** (`git show <sha>:<path>`); a carried-over patch
  describes the tree it was written against, so re-measure it before applying.
- **Examples use synthetic data** (`555-01xx`, `example.com`). Before shipping a
  public-repo diff, grep it for every real value the session handled.
