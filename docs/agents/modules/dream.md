# Dream
<!-- registry: the bank of good answers, in a platform sequence, one per soul and step moment cards; capture and sign-off -->

## Status: Active

The shared `dream` SOP. A **dream** is one worked decision from a past session:
the question the session faced, the good answer, and why that answer was right.
A session reads approved dreams beside the documentation, so it meets a familiar
situation already knowing how a good session answered it.

Docs say what the rules are. Dreams show judgment being used.

## Three layers

| Layer | Holds | Loads | Lives in |
|---|---|---|---|
| **Platform** (general: who) | the universal decisions, then the helper roster: which soul does which work and how to brief one | at every session start | `docs/agents/dreams/platform/` |
| **A soul's** (specific: what) | that seat's own decisions | when the soul is invoked or launched as a subagent; a claim loads the ones that match the task | `docs/agents/dreams/<soul>/` |
| **An SOP step's** (situational: where) | the judgment calls of one step of one SOP | as a moment card, printed by the command that runs that step | `docs/agents/dreams/sops/<sop>/` |

A soul's skills are its dream sequence plus its role page. The tags decide the
layer: a dream with `sop:` and `step:` tags is a step dream; otherwise a dream with
no `soul` tag is platform. A dream tagged for several souls loads in each of their
sequences and lives under the first. Directories use the `config/souls.yml` slugs
(`turf-monster`, `ray`). The design behind the layers is
[`../system/context-layers-design.md`](../system/context-layers-design.md).
[`../dreams/INDEX.md`](../dreams/INDEX.md) lists every dream by sequence and step.
The hub's `/dreams` page (admin only, linked from `/agents`) shows the bank as
an org chart: platform dreams on top, then each soul's dreams by stage, then the
SOPs it runs with a dream count each and, under each SOP, its step dreams by step.
Each card carries its fire count ([Fired](#fired--the-heat-map)) and mean grade, a
proposed one carries Alex's Approve button ([Act 3](#act-3--sign-off-alex)), and an
approved one his Retire button. A KPI strip and the open swap proposals sit on top
([Act 4](#act-4--the-loop-every-wrap)).

## Budgets: a full layer means a swap, not an add

Every approved dream costs context in each session that loads it, so each layer
has a cap on **approved** dreams. Proposed dreams do not count until Alex
approves them.

| Layer | Cap |
|---|---|
| Platform | 15 |
| Each soul | 20 (a dream tagged for several souls counts against each) |
| Each SOP step | 5 |

`bin/dream index --check` refuses a bank with a layer over its cap and names the
layer; `test/lib/dream_bank_test.rb` pins the real bank to the caps, so going
over fails CI. **A full layer means a swap, not an add:** to approve a dream into
a full layer, retire (delete) or re-tag one already there in the same change.
At wrap, a session proposes that swap from the data ([Act 4](#act-4--the-loop-every-wrap)).

## Moment cards: step dreams at the step

A **step dream** carries two tags and no `soul`:

```yaml
sop: building-sop   # a registered SOP: an invocation in the SOP Registry
step: begin         # one lowercase token, from the table below
```

The command that runs that step prints the step's approved dreams as a short
**moment card** (question, answer and slug; no Why) after its own key output, so
a `tail` keeps the command's result and the card together. The card is read from
the tracked bank, offline: no token, no board, no network. One helper prints it,
`DreamBank.moment(sop:, step:)`, and it never raises and never changes the
command's exit status. A step with no approved dream prints nothing.

| `sop` | `step` | Printed by | Where in the output |
|---|---|---|---|
| `building-sop` | `begin` | `bin/task begin` | stderr, after the soul's dream sequence and before the scout lines (they stay last) |
| `building-sop` | `submit` | `bin/submit-wait` on every outcome; `bin/submit` when it reaches the seam | stderr, after the verdict; `bin/submit` prints none on a refusal, so the log's last line stays the reason |
| `pr-review` | `claim` | `bin/task review-claim acquire`, `bin/task claim-next-review` | stderr, after the claim line; stdout stays the claim's |
| `qa-release` | `prepare` | `bin/release prepare` | stderr, after prepare's output, on a return or an abort |

A step dream may name another registered SOP and step (`clean-infra` · `reclaim`
has one); it shows on `/dreams` and in the index until a command prints that
step. Add a row here, and to `DreamBank::MOMENTS`, when one does.

A step dream does not load at session start or at a claim, and a claim does not
count it among the dreams `not shown`. Write one when the judgment belongs to a
moment in a procedure, not to a seat: "before ejecting a red `accepted` CI, re-run
the whole run" is `qa-release` · `prepare`, whoever runs the release.

## How a dream differs from its neighbours

| | What it holds | Who admits it | Where it lives |
|---|---|---|---|
| **Dream** | a question, a good answer, the reason, the story | Alex signs off each one | `docs/agents/dreams/<sequence>/<slug>.md`, tracked |
| **Insight** | a one-line lesson graded from an activity | Ray banks it (`grade-events`) | the board's Insight Bank |
| **Provider memory** | one session's private notes | nobody | `~/.claude/…/memory/`, scratch |

A dream is the only one of the three that carries its reasoning, and the only one
Alex approves by hand.

## Act 1 — Dream (every session start, and every soul)

The platform sequence loads automatically. `bin/session-insights`, wired as the
SessionStart hook for Claude and Codex, prints a `## Dreams` block and a
`### Helper agents` roster ahead of the insights. It reads the tracked files, so
it needs no token and no board.

A soul's dreams load when the soul takes its seat. A command that names a task
prints the dreams selected for that task ([below](#a-claim-loads-the-dreams-that-match-its-task));
the others print the soul's whole sequence:

| Command | Prints | To |
|---|---|---|
| `bin/task begin … --agent <soul>` | the selected set | stderr |
| `bin/task review-claim acquire <slug> --agent <soul>` | the selected set | stderr |
| `bin/task claim-next-review --agent <soul>` | the selected set | stderr; stdout stays the slug |
| `bin/dream <soul> --task <slug>` | the selected set | stdout |
| `bin/agent-activity heartbeat <soul>` | the whole sequence | stdout |
| `bin/dream <soul>` | the whole sequence | stdout |

The two review commands also use the session's acting soul when `--agent` is
absent. A soul with no approved dream prints nothing from the three claim
commands and the heartbeat.

1. Read the whole block before your first decision.
2. When your situation matches a dream's question, answer it the same way, or
   say why this case differs.
3. A subagent launched as a soul runs `bin/dream <soul>` first, with
   `--task <slug>` when it was handed a task.
4. If the session-start block is missing (a runtime with no hook, a hook
   failure), print it yourself:

   ```bash
   /Users/alex/projects/.agents/bin/dream platform
   ```

Only `status: approved` dreams load. A dream never overrides a First Rule or an
SOP: where they disagree, the rule wins and the dream is wrong.

### The ceiling: the hook holds about 25 platform dreams

Claude Code caps a hook's context at **10,000 characters**. Over that, the model
gets a file path and a 2,000-character preview, and nearly everything is lost
without a word. Dreams and insights share that one string, so the loader budgets
it (`SessionInsights::CONTEXT_BUDGET`, 9,800):

1. The insights are fetched first and kept whole. They are never trimmed for a dream.
2. The platform dreams take what is left, and degrade on purpose:
   - every dream with its Why, while that fits (about 16 dreams beside a full feed);
   - then every dream as question and answer only (about 25);
   - then as many as fit, with a closing line that says how many were left out
     and tells the session to read `docs/agents/dreams/`.
3. The helper roster is added only when it fits after the dreams. It never costs
   a dream or a Why line.

`test/lib/session_insights_test.rb` pins the real platform sequence beside a full
insight feed under the cap, with every dream and the roster present. The dream
that tips it over fails CI; it does not truncate in production. When that test
goes red, shorten a dream, retire one, or tag it for the soul it belongs to.

The hook could carry about 25; the platform budget (above) holds it to 15, so
every platform dream keeps its Why beside a full insight feed. The bank grows in
the souls' sequences, which load by relevance, and in the step dreams, which load
at their step. Codex's hook limit has not been measured.

### A claim loads the dreams that match its task

A claim reads the task from the board and scores each of the soul's approved
dreams against it (`bin/lib/dream_selector.rb`):

| The dream's tag | Scores | When |
|---|---|---|
| `repo` | 3 | the task names that repository |
| `risk` | 3 | the task carries that risk tag |
| `shape` | 2 | the task has that shape |
| `stage` | 1 | the task is at that stage: `building` at a begin, `submitted` at a review |
| `topic` | 1 a word, 3 at most | the word is in the task's title or acceptance |

A tag value the task does not carry scores 0. Topic words are compared in lower
case, without a short list of stop words, and a word over three letters loses
one trailing `s`.

The claim prints the 12 highest scores in rank order, ties in slug order, then
the platform sequence under `### Platform dreams`. A soul with 12 dreams or fewer
has them all selected. The block stays within 6,000 characters
(`DreamBank::CALL_BUDGET`), the selected dreams take that budget first, and the
block degrades in this order:

1. every dream with its Why;
2. the selected dreams with their Why, the platform dreams without;
3. platform dreams dropped from the last up, until none is left;
4. the selected dreams without their Why;
5. selected dreams dropped from the lowest rank up.

`test/lib/dream_bank_test.rb` pins the real bank: every soul's selected dreams
fit the budget with their Why lines.

The last line counts every approved dream the block does not show, in any
sequence, and names the command that lists them:

```text
6 not shown: bin/dream list --task <slug>
```

`bin/dream list --task <slug>` prints every approved dream with its score for the
task and the path of its file. `bin/dream list` prints them unranked.

Selection never fails a claim. When the task cannot be read, the claim prints the
soul's whole sequence and `bin/dream` says so on stderr. When the bank cannot be
read, the claim prints no dreams. The exit code is the claim's own.

## Act 2 — Capture (when a session earns one)

Propose a dream when one of these happens:

- Alex says "good call", or accepts a recommendation that went against the
  obvious move.
- A review, or Alex, catches a decision that was wrong, and the right answer is
  now clear. A dream may be born from a bad decision; it records the good one,
  and its story says plainly that the session got it wrong.
- You chose not to do something tempting, and the reason would transfer.

Write the file in your task's desk, under `docs/agents/dreams/platform/`, the
soul's directory, or `docs/agents/dreams/sops/<sop>/` for a step dream. Let it ride a change that is already going through the cycle,
or open a `docs` task for it. Run `bin/dream index --write` and commit the index
with it.

```markdown
---
question: "The situation, asked in the first person as the session meets it?"
answer: "What to do, in one or two sentences."
why: "The measured cost or the fact that makes the answer right."
status: proposed
source: "2026-10-04 · task slug or session"
soul: carl
topic: [review, merge]
---

# Title

## Situation
## The pull
## What happened
```

The file name is the dream's slug, and it is unique across the whole bank, not
only its sequence: `bin/dream fired <slug>` and the /dreams fire count name a
dream by slug alone. `status` is read in any case (`Proposed` is proposed), on the
page and by `bin/dream apply-approvals` alike.

Tags are optional, and each takes one value or a list of lowercase tokens:

| Tag | Says | Checked against |
|---|---|---|
| `soul` | whose sequence loads the dream; absent means platform | `config/souls.yml` slugs |
| `repo` | the app it is about | not checked |
| `shape` | the feature shape it applies to | not checked |
| `risk` | the risk tag it applies to | not checked |
| `stage` | the task stage it applies at | not checked |
| `topic` | free words, matched against the task's title and acceptance | not checked |
| `sop` | the SOP a step dream belongs to; needs `step` and no `soul` | the SOP Registry (`bin/lib/sop_registry.rb`), where the SOP files can be read |
| `step` | the step within that SOP; one value | one lowercase token |

On a soul's dream the last five tags decide which claims load it. Spell each
value as the board spells it (`turf-monster`, `payment`, `ui+db`, `submitted`).

A file with an unknown front matter key, an unknown soul, an unknown SOP, a `sop`
without one `step` (or the reverse), a step dream with a `soul`, or a tag value
that is not one token loads nowhere. `test/lib/dream_bank_test.rb` fails on it, on a
dream filed under the wrong directory, and on a stale index.

Rules for a dream:

- **One decision.** If it needs "and also", it is two dreams.
- **The question is the trigger.** Write it the way a future session will feel
  it, before it knows the answer.
- **The pull is named.** Say what the tempting move was. A dream with no
  temptation is a fact, and facts belong in the docs.
- **No live data.** This repo is public. No real names of counterparties, no
  figures from a deal, no contact details, no keys or addresses.
- **No security detail.** Do not name a weakness that may still be open (which
  key is shared, what leaked). Say that one was found.
- **Short.** Question, answer and why together stay under about 400 characters;
  every character is spent out of the ceiling above or a claim's 6,000.
- **New dreams are `proposed`.** Never write `approved` yourself.

### The grader proposes one at ship

`Insights::TaskGrader` grades every task once when it ships. The same call asks
`Insights::DreamProposer` for at most one proposed dream, from the task's notes.
The signals and phrases are in `config/learning_loop.yml` under `dream`; the
first signal in that order claims the proposal.

| Signal | Fires when the task carries | The dream is for |
|---|---|---|
| `overruled_block` | a block, a `CONTEST:` clarification after it, then `RULING: OVERRULE` | the contest's author, else the task's builder |
| `corrected_block` | a block, a `CONTEST:` clarification after it, then `RULING: ACCEPT` or `SPLIT` | the soul that raised the block |
| `ruling` | a `RULING:` note naming `ACCEPT`, `OVERRULE` or `SPLIT` | the ruling's author |
| `operator_praise` | a note containing an operator phrase | the author of the newest handoff before it by another soul, else the task's builder |
| `review_praise` | a scout report or a handoff, by a soul other than the builder, containing a review phrase | the same |

A signal whose soul is not in `config/souls.yml` is skipped, and the next is tried.

The proposal is the triage finding `dream-proposal-<task-slug>`, whose body is
the dream file. One finding per task: a second grade, or a dismissed finding,
adds none. The grader writes no file, and a proposer failure is logged and
leaves the grade recorded.

**What a draft holds.** Note text is read to detect a signal and never copied.
The draft is a fixed template per signal, filled from these fields only:

- the task's slug, title, shape, repositories and risk tags;
- each source activity's slug;
- soul slugs, and the ruling's verdict word.

**What is dropped.** A draft is dropped, with a log line naming the task slug
and the rule and nothing else, when:

- the task title or slug holds the first and last name of a row in the people table (a soul's is allowed);
- the draft holds an email address, a phone number, a money amount, a run of
  six or more digits, or a comma-grouped number. Activity slugs are not counted.

A single name, a company name and a number under six digits pass the screen; the materializing session reads the draft against these rules.

**Materialize it.** In a hub task desk:

```bash
/Users/alex/projects/.agents/bin/dream propose --materialize dream-proposal-<task-slug>
```

It writes `docs/agents/dreams/<soul>/<task-slug>.md` in that desk with
`status: proposed`. It refuses outside a desk, refuses a finding that is not a
proposed dream for one known soul, and never overwrites a file. Then:

1. Read the source activities named in `source`, and rewrite the title, the
   question, answer, why and the three sections to the decision the task made.
   The title and the file name come from the task: reword or rename one that
   names a client, a company or a person, because this repository is public.
2. Run `bin/dream index --write` and commit both files.
3. Ask Alex to sign off (Act 3). A proposed dream loads in no sequence; the index lists it `proposed`.

## Act 3 — Sign-off (Alex)

Alex approves each dream, in one of two ways: his click on `/dreams`, or his word
in chat, which the session records with his quoted words. Either way the row waits
for a batch task to write it into the files.

**One click on `/dreams`.** A proposed dream's card has an **Approve** button for
Alex. The click records a `DreamApproval` row; the card then reads *Approved,
loads after the next release*. Only Alex's own signed-in account can click:
another admin seat sees no button and is refused. The only API route that
creates an approval is the chat ruling below, and only on his quoted words.
The file still reads `proposed` until a batch task writes it:

1. `bin/dream approvals` lists the pending approvals
   (`GET /api/v1/dream_approvals`). `qa-release` checks it before each sweep.
2. In one hub task desk, `bin/dream apply-approvals` sets each pending file to
   `status: approved` and rewrites `INDEX.md`. It carries out Alex's recorded
   click; it is not an agent approving. A file that no longer reads
   `proposed`, or is gone, is skipped and named. The same run deletes the file
   of each retirement Alex recorded (`GET /api/v1/dream_retirements`, Act 4).
3. Commit and submit that one task for every pending approval, never one task per
   dream.
4. Once the release ships, the deployed file reads approved, and `/dreams` and
   the approvals read mark the row applied. Nothing is marked by hand.

**In chat.** Put the decisions to him as cards ([The card standard](#the-card-standard)),
then record each answer he gives with his exact words:

```bash
/Users/alex/projects/.agents/bin/dream approve <slug> --clearance "<Alex's exact words>"
/Users/alex/projects/.agents/bin/dream drop    <slug> --clearance "<Alex's exact words>"
/Users/alex/projects/.agents/bin/dream retire  <slug> --clearance "<Alex's exact words>"
```

Each posts `POST /api/v1/dream_rulings` (`DreamRuling`), the chat twin of
`bin/release ship --mode cleared --clearance`: his clearance in chat is the
grant, and the words are the audit trail, not a signature.

| Ruling | Takes | Records | `apply-approvals` then |
|---|---|---|---|
| `approve` | a proposed dream | a `DreamApproval` | sets `status: approved` |
| `drop` | a proposed dream | a `DreamRetirement`, ruling `drop` | deletes the file |
| `retire` | an approved dream | a `DreamRetirement`, ruling `retire` | deletes the file |

- Every row is stamped `via: chat`, with the verbatim clearance and the session
  id, and names Alex as the approver. `/dreams` shows the quote beside the
  approval, drop or retirement; a click carries none.
- The clearance is refused when it is empty, only the dream's slug, or shorter
  than three words (`bin/lib/dream_clearance.rb`, checked by the CLI and again by
  the board). A reply in the card grammar stands as it is: `yes`, or per-number
  answers such as `1 ✓ 2 ✗`.
- The board holds the ruling to the dream's status, refuses an approval and a
  drop of the same dream, and answers a second ruling with the first row (his
  click included).
- The dream must be in the deployed bank. A dream that exists only in your desk
  is ruled in its file, on the same words: set `status: approved`, or delete the
  file, and quote him in the PR.
- **An agent never approves on its own judgment.** It records only what Alex said
  in that session, quoted. A grade, a swap proposal, a card's "My call" and his
  silence are never an approval.

### The card standard

One format puts every dream decision to Alex in chat, at wrap and on demand
(the [`dream-swap`](dream-swap.md) SOP). `bin/dream cards` renders it
(`bin/lib/dream_cards.rb`); paste its output, and fill in your call.

```text
2 dream decisions for you: 1 add, 1 swap.

1 · ADD · step/qa-release/prepare · 0 of 5 used
   Q: "At `bin/release prepare`, `accepted` CI is red on one e2e spec. Do I eject the PR?"
   A: "Not yet. Re-run the WHOLE run and eject only if it is red again."
   Why: "A spec fresh on `accepted` can be flaky; an ejection costs the PR its release."
   Evidence: source 2026-10-15 · qa-release · sops/qa-release/rerun-the-whole-run-before-ejecting.md
   My call: approve — a judgment call at a step, and no command can make it

2 · SWAP · soul/carl · 20 of 20 used
   Q: "…"
   A: "…"
   Why: "…"
   Evidence: source 2026-10-12 · task x · carl/new.md; OUT `carl/old` · mean 0.5 of 2 · 3 fired · last 2026-10-01
   My call: drop — a must-do: `bin/x` already refuses it

Reply: `yes` takes every call · `1 ✓ 2 ✗ 3 ✎ <edit>` per number · or plain words. …
```

1. **One idea line** first: how many decisions, and of which kinds.
2. **Numbered cards.** Each has:
   - a header `N · ADD|SWAP|RETIRE · <layer> · <used> of <cap> used`. ADD when
     the layer has room, SWAP when it is full (the in with its out), RETIRE for an
     approved dream whose grades say it misleads (mean under 0.5 over two or more);
   - **Q, A and Why** quoted from the file;
   - **one Evidence line**: the source; for a swap, also the OUT dream's slug,
     mean grade, fires and last fire;
   - **My call**: approve, change or drop, with a one-line reason. Before the
     call, apply the test: **a must-do belongs in a command, not a dream.** If a
     command could enforce the answer, the call is drop, and the fix is the
     command. The card flags an answer that opens like a rule (`Always`, `Never`,
     `Must`).
3. **The reply grammar**, last:
   - `yes` takes every call in the message;
   - per number: `1 ✓ 2 ✗ 3 ✎ <edit>`. ✓ takes that card's call, ✗ refuses it
     (nothing is recorded unless his words say what instead), ✎ takes it with his
     edit. Plain words work too;
   - **silence changes nothing.** Unlike the decisions that stand on silence
     ([`communication-style.md`](communication-style.md#dream-decisions-the-card-standard)),
     a dream never defaults: no reply, no ruling.

Record each answer with `bin/dream approve|drop|retire <slug> --clearance` and his
words: his whole reply, or the grammar token (`yes`, `1 ✓`). A `✎` changes the
file in your desk first; the changed dream is ruled once it ships.

## Fired — the heat map

When a dream changes what you do, record it:

```bash
/Users/alex/projects/.agents/bin/dream fired <slug> --decision "<what it changed>"
```

It posts a `dream_fired` action to your open activity (through
`bin/agent-activity action`), with the dream's slug and the decision, cut to 160
characters. It refuses an unknown dream, and says so when nothing was recorded
(no open activity). The session-start header asks for it.

`/dreams` shows each dream's fire count and its three newest decisions. Those
rows are kept past the 45-day action retention, so the count is all-time.

## Act 4 — The loop (every wrap)

Fires say which dreams shaped decisions. At wrap, the session judges them and
keeps the bank within its budgets. The `wrap-it-up` SOP carries the step
([`wrap-it-up.md`](../agents/pokemon/sops/wrap-it-up.md)).

**1. Grade what fired.** For each dream with a `dream_fired` action in this
session, name the decision it shaped and score it:

```bash
/Users/alex/projects/.agents/bin/dream grade <slug> --score 0|1|2 --decision "<the decision>"
```

| Score | Means |
|---|---|
| 0 | it fired and its answer was wrong for this case |
| 1 | it fired and helped |
| 2 | it fired and decided the outcome |

The board refuses a dream that did not fire in this session (no `dream_fired`
action under the session's id), a second grade of it here, and a grade with no
decision. A grade is agent-written data, never an approval: it changes no file
and no status. It feeds the swap ranking and `/dreams`.

**2. Propose at most one swap.** Each layer has a cap on approved dreams
([Budgets](#budgets-a-full-layer-means-a-swap-not-an-add)). Read the room and the
candidates:

```bash
/Users/alex/projects/.agents/bin/dream swap-candidates [--layer platform|soul/<slug>|step/<sop>/<step>]
```

- **The layer has room:** a swap is one add. Write the new dream as `proposed` in
  your desk (Act 2), then `bin/dream swap --in <home>/<slug> --reason "..."`.
- **The layer is full:** a swap is one in and one out:
  `bin/dream swap --in <home>/<slug> --out <home>/<slug> --reason "..."`. The out
  must be one of the layer's eligible candidates.
- **Nothing earned a place:** `bin/dream swap --none --reason "..."`. "No swap" is
  a full answer, and it is recorded.

One answer per session; the board refuses a second. `--in` must be a file reading
`status: proposed` in this desk's bank; its layer is read from the file.

**Then put it to Alex as a card** ([The card standard](#the-card-standard)), the
last thing the Dreams step does:

```bash
/Users/alex/projects/.agents/bin/dream cards --in <home>/<slug> [--out <home>/<slug>] --call <slug>=approve:"<reason>"
/Users/alex/projects/.agents/bin/dream cards --none      # "Dreams: no swap this session."
```

At most one swap card, or the no-swap line. Record his reply as Act 3 says. While
the in is still only in your desk, rule it in that desk's files: on his quoted
`yes`, set the in to `status: approved` and delete the out's file in the same
change (the budget check holds the layer to its cap), and quote him in the PR.
Once the in has shipped, `bin/dream approve <in>` and `bin/dream retire <out>`
record it, or his **Approve swap** click does.

**How the out is chosen.** `swap-candidates` ranks the layer's approved dreams by
the data: lowest mean grade first (an ungraded dream counts as 1.0), then longest
since its last fire (never fired first), then slug. A dream already retiring is
not a candidate, and neither is one in its **grace**: the first 10 sessions after
its approval. Loads are not recorded, so the proxy is the number of distinct
sessions that opened an activity since the approval. Every session loads the
platform layer; a soul's or a step's dreams load in fewer, so the proxy ends
their grace sooner. The approval time is the `/dreams` click, else the date that
opens the dream's `source:` line; a dream with neither predates the loop and is
past grace.

**3. Alex approves on `/dreams`, or in chat.** The open swaps sit above the chart. His
**Approve swap** click records the in through the Act 3 approval and the out as a
retirement, together. A **Retire** button on any approved card retires one on its
own. Both are his alone, checked exactly as Approve is: another admin seat sees no
button and is refused. In chat, his word does the same through
`bin/dream approve` and `bin/dream retire` ([Act 3](#act-3--sign-off-alex)).

The next batch task's `bin/dream apply-approvals` writes both: it sets each
approved file to `status: approved` and **deletes** each retired file (Act 3's
"Dropped: delete the file"; no `retired` status is ever written), then rewrites
`INDEX.md`. Once the release ships, `/dreams` marks each one applied.

**The KPI strip.** `/dreams` opens with four numbers (`DreamKpis`):

| KPI | Measures |
|---|---|
| Fire rate | dream fires per session, over sessions that opened an activity in the last 30 days |
| Mean grade | the mean of the grades given in the last 30 days, 0 to 2 |
| Swaps per week | swaps and adds Alex approved over the last 4 weeks, per week (and the no-swap answers) |
| Approval latency | median days from a dream's proposal (its `source:` date) to Alex's click, over the newest 100 approvals |

Each card shows its mean grade and fire count, and its heat: cold (never fired),
warm (1 to 4 fires), hot (5 or more).

**Budgets in one place.** `bin/lib/dream_layers.rb` names the layers a swap
works in and reads its caps from `DreamBank::BUDGETS`, the same constant
`bin/dream index --check` enforces ([Budgets](#budgets-a-full-layer-means-a-swap-not-an-add)).

## When Alex says `dream`

Run Acts 2 and 3 for the current session: list the decisions from this session
worth keeping, write them as `proposed`, show any other proposed dreams still
waiting, including the open `dream-proposal-*` findings
(`bin/triage list --status open`), and ask for sign-off as cards
([The card standard](#the-card-standard)). When he says `dream-swap`, run the
[`dream-swap`](dream-swap.md) SOP: the cards for every pending dream and the swaps
the data calls for.

## Files

| Piece | Path |
|---|---|
| The bank | `docs/agents/dreams/platform/`, `docs/agents/dreams/<soul>/` |
| Generated index | `docs/agents/dreams/INDEX.md` (`bin/dream index --write`) |
| Parser, sequences and formatter | `bin/lib/dream_bank.rb` |
| Selector | `bin/lib/dream_selector.rb` |
| Budgets and moment cards | `bin/lib/dream_bank.rb` (`BUDGETS`, `MOMENTS`, `moment`, `after_moment`) |
| Session-start loader | `bin/session-insights` |
| Soul loader, list, materialize, approvals, fired, grade, swap, cards, chat rulings | `bin/dream` |
| One-click approvals | `app/models/dream_approval.rb`, `DreamsController#approve`, `app/controllers/api/v1/dream_approvals_controller.rb` |
| Chat rulings | `app/models/dream_ruling.rb`, `app/controllers/api/v1/dream_rulings_controller.rb`, `bin/lib/dream_clearance.rb`, `app/views/dreams/_clearance.html.erb` |
| The card standard | `bin/lib/dream_cards.rb` (`bin/dream cards`); the on-demand SOP [`dream-swap.md`](dream-swap.md) |
| Heat map | `app/models/dream_heat.rb` (`dream_fired` actions) |
| The loop: grades, swaps, retirements, KPIs | `app/models/dream_grade.rb`, `dream_swap.rb`, `dream_retirement.rb`, `dream_loop.rb` (room, candidates, grace), `dream_kpis.rb`; `bin/lib/dream_layers.rb` (layer keys, budgets) |
| Loop API | `app/controllers/api/v1/dream_grades_controller.rb`, `dream_swaps_controller.rb`, `dream_retirements_controller.rb`; `DreamsController#retire`, `#approve_swap` |
| Ship-time proposer | `app/services/insights/dream_proposer.rb`, called by `app/services/insights/task_grader.rb` |
| Signals and phrases | `config/learning_loop.yml` (`dream`) |
| Installed copy the hook reads | `bin/install-agent-docs` (`TOOLING_PATHS`) |
| Tests | `test/lib/dream_bank_test.rb`, `test/lib/dream_selector_test.rb`, `test/lib/dream_cli_test.rb`, `test/lib/session_insights_test.rb`, `test/services/insights/dream_proposer_test.rb`, `test/models/dream_approval_test.rb`, `test/models/dream_heat_test.rb`, `test/integration/dreams_page_test.rb`, `test/controllers/api/v1/dream_approvals_controller_test.rb`, `e2e/dream_approve.spec.js`; the moment cards in `test/commands/task_begin_login_test.rb`, `test/lib/submit_test.rb`, `test/lib/submit_wait_script_test.rb`, `test/lib/review_claim_cli_test.rb`, `test/integration/release_prepare_moment_test.rb`, `e2e/dreams_step_dreams.spec.js`; the loop: `test/lib/dream_layers_test.rb`, `test/models/dream_grade_test.rb`, `test/models/dream_retirement_test.rb`, `test/models/dream_loop_test.rb`, `test/integration/dreams_loop_page_test.rb`, `test/controllers/api/v1/dream_loop_controllers_test.rb`, `e2e/dream_retire.spec.js`; the cards and chat rulings: `test/lib/dream_cards_test.rb`, `test/lib/dream_clearance_test.rb`, `test/models/dream_ruling_test.rb`, `test/controllers/api/v1/dream_rulings_controller_test.rb`, `test/integration/dreams_chat_ruling_page_test.rb`, `e2e/dream_chat_ruling.spec.js` |
| Fixture bank the selector tests read | `test/fixtures/dreams/` |
