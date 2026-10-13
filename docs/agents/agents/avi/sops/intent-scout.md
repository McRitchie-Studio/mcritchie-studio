# Intent Scout
<!-- registry: while a builder builds, Avi reads the task's intent and hands over one two-list brief before submit -->

## Status: Active

This is Avi's `intent-scout` SOP. While a builder builds, Avi reads the task's
**intent** (its title and acceptance), not its diff, and finds every surface each
criterion touches. He posts one short brief on the task, and the builder folds the
gaps in **before** the CI wait instead of after a red one. Avi reads; the builder
decides. The build never waits on the scout.

## Trigger

The act begins at `bin/task begin`. When `begin` claims a task, it posts an
`INTENT SCOUT OWED:` note on the task and prints a paste-ready launch:

```text
scout: Avi owes this task an intent scout (…/docs/agents/agents/avi/sops/intent-scout.md).
  Launch it now in the background and keep building; nothing waits on it:
  Agent(subagent_type: "avi", run_in_background: true, description: "Intent scout <slug>",
        prompt: "Run the intent-scout SOP at … for task <slug>. The builder's desk is <desk>: …")
```

The session that ran `begin` launches that line: the focus session that holds the
epic, or the builder itself when it runs alone. The scout counts toward the
five-agent cap, but it runs no suite, so it never counts as a certifying agent.

## Scope

One task, one brief, one pass. The scout never edits the desk, never commits,
never moves the task, never blocks it, and never reviews the diff: Carl reviews
code after `submitted`. It does not add work to the task; anything wider than the
task's intent goes into one proposed follow-up card.

## Entry

Run from the hub primary checkout, as Avi, on the production board:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity start --category Research --agent avi --task <slug> --reason "intent scout: <slug>"
/Users/alex/projects/.agents/bin/dream avi --task <slug>
```

## Procedure

Aim for about ten minutes, so the brief lands before the builder's submit does.

1. **Read the intent.** Title, acceptance, `agent_context`, shape, risk, repos, and
   the epic plan if the context names one:

   ```bash
   bin/task show <slug> -v
   ```

   Hold each acceptance criterion as one sentence: after this task, X is true.

2. **Find every surface each criterion touches.** Search the whole repository for
   the nouns and values in the criterion, in the primary checkout or the desk read
   only. Search every directory a reader of that value lives in, not only the one
   the builder will open first:
   - views, partials, helpers, mailers and components;
   - models, services, jobs, config and seeds;
   - every test directory: `test/models`, `test/controllers`, `test/views`,
     `test/lib`, `test/integration`, `test/system`, and `e2e/`;
   - docs, copy, and fixtures that quote the value.

   ```bash
   git -C /Users/alex/projects/<repo> grep -n -i "<value or noun>"
   ```

   A literal value (a price, a label, a route) is the commonest miss: grep the
   value itself, in every spelling (`1,500`, `1500`, `1_500`).

3. **Find the prior art.** A past task on the board that did the same kind of
   change, and what it missed:

   ```bash
   bin/task list --stage shipped | grep -i "<noun>"
   ```

   Read the matching dreams in your sequence (Entry) and the platform sequence.

4. **Write the brief.** Exactly two lists:

   - **SAME INTENT, DO NOW**: gaps inside this task's intent that the builder must
     fold in before submit. Each item is one line: the file, and why it belongs
     (it pins the old value, it renders the same copy, it documents the flow).
   - **WIDER SCOPE, FOLLOW-UP**: anything bigger, proposed as **one** follow-up
     card, never added to this task. Alex has task fatigue, so fold every wider
     idea into that single card or write `none`.

5. **Post it on the task**, one comment beginning `INTENT SCOUT BRIEF`:

   ```bash
   bin/task note <slug> --comment "INTENT SCOUT BRIEF: SAME INTENT, DO NOW: (1) <file> - <why>. (2) … WIDER SCOPE, FOLLOW-UP: <one card title and one line>, or none." --agent avi
   ```

   That prefix is the whole contract: `bin/task scout-brief <slug>` reads the
   newest such note back, and `bin/submit` warns at 0/8 when none is on the task.

6. **Hand it to the builder** through the session that launched you: report the
   brief in your final message. Do not file the follow-up card yourself; the
   session that holds the epic files it, or folds it into a card it already holds.

7. **Close the activity**:

   ```bash
   bin/agent-activity end --outcome "brief posted: <n> do-now items, follow-up <title or none>"
   ```

## Guardrails

- **The same intent.** An item belongs on DO NOW only if the task's acceptance is
  false without it. A better idea is a follow-up, however small.
- **Short.** A handful of lines. Name files, not essays; the builder has the code.
- **Read only.** Never edit, commit in, or run a suite in the builder's desk. A
  scout that writes the desk is a second builder with no claim.
- **The builder decides.** The brief is advice. A builder may decline an item and
  should say why in its report; the reviewer reads both.
- **Never a gate.** Nothing waits on the scout. A missing brief costs a warning at
  submit, never a refusal.

## Worked example: team-tier-nine-hundred (2026-10-13)

The task changed the Team tier on `/packages` from $1,500 to $900 a month. The
builder edited the packages view and its test, submitted, and CI went red:
`test/views/stack_view_test.rb` also pinned `$1,500`. The fix was one line, and
the round trip cost twelve minutes.

A scout reading the intent ("the Team tier reads $900") greps the value in every
spelling across the repository and returns:

```text
INTENT SCOUT BRIEF: SAME INTENT, DO NOW: (1) test/views/stack_view_test.rb - asserts the old $1,500 Team price.
(2) any doc or copy quoting the Team price - grep 1,500 and 1500. WIDER SCOPE, FOLLOW-UP: none.
```

The builder folds item 1 in before the push, and CI is green the first time.

## Exit seam

One `INTENT SCOUT BRIEF` comment is on the task, with both lists; the desk is
untouched; the activity is closed. Report the brief, and the follow-up card you
proposed, to the session that launched you.

## Related

- [`../../../modules/building-sop.md`](../../../modules/building-sop.md): the builder reads the brief before submit.
- [`../../../modules/focus-session.md`](../../../modules/focus-session.md): the session that launches the scout beside each builder.
- `bin/lib/intent_scout.rb`: the marker, the begin lines and the submit warning.
