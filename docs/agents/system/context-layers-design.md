# Context layers — design

**Status: situational layer built.** Written with `scout-launches-itself`
(2026-10-13), which built the split between mechanical must-dos and judgment
dreams for the intent scout. `step-dreams-and-moment-cards` (2026-10-15) built
section 5: SOP-step dreams, their moment cards and the per-layer budgets. The
procedure is [`../modules/dream.md`](../modules/dream.md).

The idea in one paragraph: an agent's context comes in three layers. The
**general** layer says who it is and loads at session start. The **situational**
layer says where it stands: the step of the SOP it is in, with that step's
must-dos and traps. The **specific** layer says what it is working on: the task,
Avi's brief, the dreams matched to that task. General loads on start and stays
small. Situational and specific load on the first real request and again whenever
the ground shifts. And one rule decides where each piece of guidance lives: **a
must-do is mechanical, a judgment call is a dream.**

## 1. The motivating case: navbar-first-name-only

On 2026-10-13 a fresh builder claimed `navbar-first-name-only` with
`bin/task begin ... 2>&1 | tail -30`. `begin` printed its `scout:` launch block
(stdout) **before** the dream bank (stderr), and that night the dream bank ran past
thirty lines. `tail` cut the block, so the builder never saw it and never launched
Avi's intent scout. Nothing else would have caught it:

- the builder read `building-sop.md` lines 55-80; the scout rule sat at line 88;
- `CLAUDE.md` and `AGENTS.md` named `intent-scout` only in the SOP registry;
- the scout's only trace on the board was an `INTENT SCOUT OWED` note nobody reads
  at claim time.

The rule was right and well documented. It failed because it was a must-do that
depended on a reader noticing a printed line at the right moment.
`scout-launches-itself` made it mechanical: `begin` now launches the scout itself,
detached, and prints what it did last, after the dream bank.

## 2. The three layers

| Layer | Answers | Holds | Loads | Size |
|-------|---------|-------|-------|------|
| **General** | Who am I? | First Rules, the pipeline, the SOP registry, the platform dreams | At session start (`CLAUDE.md` → `AGENTS.md`, the session-start dream sequence) | Small, by budget; every line costs every session |
| **Situational** | Where am I? | The current SOP step: its must-dos, its traps, its exit seam | On the first real request, and on entering each SOP step | One step's worth |
| **Specific** | What am I working on? | The task (title, acceptance, context), Avi's brief, the dreams matched to the task's tags | On the first real request that names a task; re-read before submit | One task's worth |

The general layer is the only one that loads unasked, so it is the one that must
stay small: it carries pointers, not procedures. The other two are pulled.

## 3. Timing: when to pull again

General loads on session start. Situational and specific load on the **first real
request**: not as a hard rule, but because before it the agent does not yet know
where it stands or what it holds. After that, an agent re-pulls whenever the
ground shifts:

- **The first request** of a session or of a spawned agent.
- **Entering an SOP step** (claim, build, local review, submit, review, release).
- **A new task, repo or soul**: a different desk, a different app, a different seat.
- **Alex McRitchie redirects**: a new instruction replaces the plan the context was pulled for.
- **A surprise**: a red CI, a refusal, a block, a number that does not match. A
  surprise means the agent's picture of where it stands is wrong, so it re-reads
  the step and the task before acting. Surprises are also where new dreams come
  from: the answer that resolved one, signed off by Alex McRitchie, becomes the next
  agent's dream.

## 4. The split: must-do is mechanical, judgment is a dream

| Kind | Example | Where it lives | Why |
|------|---------|----------------|-----|
| **Must-do** | Launch Avi's intent scout at claim | A script or hook: `bin/task begin` launches it (`IntentScout.auto_launch`) | A step that must happen every time cannot depend on someone reading a line; the machine does it and says so |
| **Must-do** | Record test tiers before submit | A refusal: `bin/dor-check --precheck` at 0/8 | Same; the check is cheap and the miss is expensive |
| **Judgment** | Does this change earn Alex McRitchie's local look? | A dream and the SOP's one judgment step | There is no rule to automate; a worked past answer is the best guide |
| **Judgment** | Fold a scout item in, or decline it? | A dream; the builder says why in its report | The builder decides; the brief is advice |

The test for which kind a piece of guidance is: **could a script decide it from
the records alone?** If yes, it is a must-do, and prose describing it is a backup,
not the mechanism. If it needs reading the situation, it is a dream, and it should
reach the agent at the moment the situation arises (section 5).

When a must-do cannot be fully mechanical (the scout falls back to a printed block
when there is no `claude` CLI), the fallback output goes where it cannot be cut:
**last**, after every other block, and named once more in the summary at the top,
so both `head` and `tail` keep it.

## 5. Built: SOP-step dreams as moment cards

Today a dream is matched by its tags (`soul`, `repo`, `shape`, `risk`, `stage`,
`topic`; `DreamBank::TAGS`) and shown at session start or at claim. A judgment that
belongs to one step of one SOP (say, "before submit: fold the brief or decline it,
and say why") is shown far from the moment it applies.

**Built (2026-10-15).** Two front-matter tags:

```yaml
sop: building-sop        # the SOP the dream belongs to (its registry name)
step: submit             # the step within it
```

and each command that runs a step prints the matching approved dreams as a short
**moment card** after its own key output: `bin/task begin` for `building-sop` ·
`begin`, `bin/submit` and `bin/submit-wait` for `building-sop` · `submit`,
`bin/task review-claim acquire` and `claim-next-review` for `pr-review` · `claim`,
and `bin/release prepare` for `qa-release` · `prepare`. A card is question and
answer with the slug, no Why, from the tracked bank, offline, through one helper
(`DreamBank.moment`) that never raises. At `begin` the card prints before the
scout lines, which stay last. The step names and where each card prints are in
[`../modules/dream.md`](../modules/dream.md#moment-cards-step-dreams-at-the-step).

What was decided in the build:

- **A step dream is its own layer.** It names one registered SOP and one step and
  carries no `soul`; it lives under `docs/agents/dreams/sops/<sop>/`, never loads
  at session start or at a claim, and the selector does not match on it.
- **Budgets per layer.** Platform 15, each soul 20, each SOP step 5 approved
  dreams; proposed dreams do not count. `bin/dream index --check` and a test on
  the real bank fail over a cap. A full layer means a swap, not an add.
- **`/dreams`** shows each step dream under its SOP and step.

## 6. Related

- `bin/lib/intent_scout.rb`: the auto-launch, the first mechanical must-do built
  from this split.
- [`../agents/avi/sops/intent-scout.md`](../agents/avi/sops/intent-scout.md): the scout's SOP and its Trigger.
- [`../modules/dream.md`](../modules/dream.md): the dream bank and how a sequence is chosen.
- [`../modules/building-sop.md`](../modules/building-sop.md): the builder's steps, which section 5 would annotate.
