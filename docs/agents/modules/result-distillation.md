# Result Distillation

The trajectory should record **findings, not raw operations**. A raw tool result
is **DATA** — the bytes a Read, a Grep, a `bin/dor-check`, or a test run returned.
A **distilled finding** is that same data **plus the agent's judgment** about what
it means for the work. Only the reasoning agent can perform that reduction, so
distillation is a **behavioral policy on the honor system**, not something a hook
can synthesize.

This is the OPSD **Distill** grain applied to a single tool result: the same
reduce-signal-from-noise move the learning loop makes over a whole session, made
one result at a time, live, by the agent producing the result.

## The principle

- A raw result answers *"what did the tool return?"* It is captured
  automatically — the `PostToolUse` capture hook writes one `AgentAction` row per
  tool call, attributed to whichever activity is open. That layer is free and
  needs no agent effort.
- A distilled finding answers *"what did I learn, and what does it change?"* It
  exists **only** if the agent writes it. A raw re-read left as the record forces
  the next reader (another agent, Mr. McRitchie, the learning loop) to re-derive
  the judgment the agent already made.
- So: when a result **decides** something, the agent records the decision — the
  finding — not just the operation that produced it.

## The policy

When a tool result is **decision-bearing** — a diff, a `bin/dor-check`, a test
run, a query that informs a verdict or the next step — the agent records a
**distilled finding**: a one-line `validate → resolve` in the shape

> **checked X, found Y, therefore Z**

recorded with:

```bash
bin/agent-activity action --summary "checked <X>, found <Y>, therefore <Z>"
```

`action` self-reports one finding as an `AgentAction` (actor `agent`) attached to
the currently-open activity, so the trajectory shows the *judgment* beside the raw
rows instead of a bare re-read the next reader has to interpret. It is
**non-fatal** narration — it never blocks the work.

Routine **paging re-reads** — reopening a file only to see the next chunk, with no
judgment attached — are **not** findings and should be **suppressed** rather than
distilled (that suppression is a separate mechanism; this policy governs the
positive case: *when there IS judgment, record it*).

## Two grains, nested

Distillation happens at two nested grains. Both already exist as commands; this
policy is about **using them as a reduction ladder**, not about new machinery.

| Grain | What it is | How it's recorded | Answers |
|---|---|---|---|
| **Action-level finding** | The judgment on ONE decision-bearing result | `bin/agent-activity action --summary "checked X, found Y, therefore Z"` | "What did this result tell me?" |
| **Activity-level verdict** | The outcome that SYNTHESIZES an activity's findings | the `--outcome` on `bin/agent-activity next` / `end` | "What did this unit of work conclude?" |

The verdict is the coarser reduction: it rolls several action-level findings into
the one sentence that survives as the activity's result (`"Explore: find api issue
→ found the nil-guard"`). An activity that closes with no outcome — or whose
outcome merely restates the intent — has thrown away the distillation.

## Progressive roll-up

Each grain reduces the one below it. The chain is a signal funnel: many raw
results collapse into a few findings, findings collapse into a verdict, verdicts
feed the learning loop.

```
raw tool result        (DATA — auto-captured, one row per tool call)
  └─ action finding     (DATA + judgment — bin/agent-activity action --summary)
       └─ activity verdict   (the --outcome that synthesizes the findings)
            └─ learning-loop insight   (Alex heartbeat distills verdicts → banked insight)
```

Reading up the ladder recovers *why*; reading down recovers *what*. The policy
keeps every rung populated so neither direction dead-ends at a wall of raw rows.

## What counts as decision-bearing

Distill when the result **changes what you do next** or **supports a verdict**:

- A diff, `git status`, or code you read to decide whether a change is correct.
- `bin/dor-check`, `bin/full-suite-check`, or a test/CI run that gates a handoff.
- A query, log, or grep whose answer picks a branch, confirms a hypothesis, or
  rules one out ("checked the FK, found it cascades, therefore reseed clears
  dependents first").
- A preflight, PR state, or overlap check that decides how to proceed.

Do **not** distill pure navigation or blind paging: a `cd`, a `pwd`, or reopening
a file only to scroll. These carry no judgment; a finding with no `therefore` is
noise dressed as signal.

## How to record a finding

- Keep the `--summary` to one line in `validate → resolve` form — name the check,
  the observation, and the consequence. "Ran dor-check, it passed" is weak; "ran
  dor-check, it flagged missing integration tier, therefore added the request
  spec" is a finding.
- Add `--key-method "<code>"` (+ optional `--key-lang bash|ruby|sql`) when one
  load-bearing call is worth copying — the exact line the next agent would rerun.
- Prefer **one finding per decision**, not one per tool call. Several raw reads
  that together settle one question are **one** finding.
- Close each activity with an `--outcome` that **synthesizes** its findings into
  the verdict — that is the second grain, and it is where the roll-up compounds.

## Honor system

Only the reasoning agent knows which results were decision-bearing, so no hook or
classifier can produce these findings — the agent must. That makes distillation a
**commitment to the protocol**, the same trust-over-guardrails posture as the rest
of the narration model: it is non-fatal, it never blocks the work, and it is the
agent's job to leave the trajectory readable as *findings* rather than a wall of
raw operations. It matters most on **review and QA lanes**, where the verdict a
reviewer records is only as trustworthy as the findings it was distilled from.

---

### Background — not needed to execute

The raw-capture layer this policy sits on top of is documented in
`docs/agents/system/atomic-capture-hook.md` (the `PostToolUse` producer and the
`AgentAction` contract); the session-level Distill grain lives in the OPSD
learning loop surfaced at `/alex/heartbeat`. Neither is required reading to apply
this policy — the commands above stand on their own.
