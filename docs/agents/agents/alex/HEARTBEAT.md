# Alex Heartbeat

## Status: Active

This is Alex's specific heartbeat SOP. Use it when Mr. McRitchie launches
`Alex Heartbeat`, `grade-events`, `share-insights`, or `full-cycle` from the
`/deployments` Heartbeats card.

The shared launcher map lives in
[`../../modules/heartbeats.md`](../../modules/heartbeats.md). The release atom
model lives in
[`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
§1.4. Those pages should summarize and link here for Alex-specific mechanics.

## Scope

Alex owns the learning loop and, when explicitly launched with ship authority,
the full release pipeline:

- Grade recent trajectory spans so useful agent behavior becomes reusable memory.
- Share Mr. McRitchie's confirmed insights into the generated lessons doc and
  installed agent docs.
- Run `full-cycle` only when the operator launched that autonomous release act or
  otherwise granted production ship authority in this session.

Do not treat `Alex Heartbeat` as implied production approval unless the launched
row is `full-cycle` or Mr. McRitchie grants that authority in-session.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/atomic-event heartbeat alex
```

Then keep normal trajectory spans open with `bin/atomic-event start|next|end`.
The heartbeat command makes spans self-attribute to Alex unless a delegated
reviewer explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

## Act Order

Run Alex's acts in the launched scope:

1. `grade-events` - grade recent resolved spans.
2. `share-insights` - publish Mr. McRitchie's confirmed insights.
3. `full-cycle` - run review -> QA -> production with explicit ship authority.

When Mr. McRitchie launches `Alex Heartbeat`, run the learning acts first:
`grade-events`, then `share-insights`. Run `full-cycle` only when the launched
row or prompt explicitly includes it, or when Mr. McRitchie grants production
ship authority in the same session.

## Act 1 - `grade-events`

**Precondition:** resolved atomic-event spans are awaiting Alex's grade. If none
are waiting, report "nothing to grade" and continue to `share-insights` when this
is the full `Alex Heartbeat` row.

Procedure:

```bash
bin/atomic-event awaiting --limit 10
bin/atomic-event grade <span-id> --disposition good --slug "<4-7 words>" --bank
bin/atomic-event grade <span-id> --disposition not --slug "<4-7 words>" --discard
```

Grade the oldest waiting spans first. Bank only insights that make the next agent
smarter; discard generic narration, routine success, and anything that should not
become instruction.

The browser path at `/alex/heartbeat` is the operator/admin equivalent. The CLI
grades as Alex; Mr. McRitchie's confirmation lane remains in the browser
pipeline.

**Exit seam:** about 10 spans graded, with useful insights banked and weak ones
discarded. Report how many were banked and discarded.

## Act 2 - `share-insights`

**Precondition:** at least one insight has been confirmed by Mr. McRitchie
(`grader: "mcr"`). If none are confirmed, report "nothing to share" and stop.

Procedure:

```bash
bin/rails insights:doc
bin/install-agent-docs
```

Regenerate the tracked lessons doc from confirmed insights, then distribute the
generated docs to the installed agent runtimes. If the generated doc changes,
include it in the branch or follow-up handoff that owns the docs update.

**Exit seam:** confirmed insights are present in the tracked lessons doc and
installed for the next agent sessions. Report the changed doc path and install
result.

## Act 3 - `full-cycle`

**Precondition:** Mr. McRitchie launched `full-cycle`, launched `Alex Heartbeat`
with full release authority, or otherwise granted production ship authority in
this session. There must also be work to move: submitted PRs to review, reviewed
work to prepare, or an assembled release to ship. Empty queue is a clean no-op.

Procedure:

```bash
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster,rolio
# pr-review atom: review submitted PRs to reviewed or blocked
bin/release prepare --yes
bin/release ship --yes
```

`full-cycle` composes the existing atoms: Avi-style review-only PR review,
Steffon's self-healing `qa-deploy`, then Avi's `production-deploy`. Keep the same
guards each atom owns: waves of five or fewer reviewers, QA-green before ship,
and no production deploy unless ship authority is explicit.

For a single-task expedite, use the dedicated `Deploy with Task <task>` SOP from
§1.4 instead of pushing one task past pending release work.

**Exit seam:** the release is shipped, or the run cleanly reports no work. Report
the reviewed/blocked tasks, QA URL, production SHA, release slug, and smoke
result when a ship happens.

## Handoff

End every Alex heartbeat with a short report:

- grading counts and any banked insight slugs
- insight doc regeneration and install result
- whether `full-cycle` was skipped, no-op, blocked, or shipped
- any production ship authority granted in-session
- any task blocked during review or ejected during QA

On a clean learning-only run, omit release sections that did not run.
