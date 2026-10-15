# Intent Scout
<!-- registry: while a builder builds, Avi reads the task's intent and hands over one two-list brief before submit -->

## Status: Active

This is Avi's `intent-scout` SOP. While a builder builds, Avi reads the task's
**intent** (its title and acceptance), not its diff, and finds every surface each
criterion touches. He posts one short brief on the task, and the builder folds the
gaps in **before** the CI wait instead of after a red one. Avi reads; the builder
decides. The build never waits on the scout.

## Trigger

The act begins at `bin/task begin`. When `begin` first claims a task, it
**launches the scout itself**: a detached, headless run of this SOP as Avi,

```bash
claude -p "<IntentScout.headless_prompt>" --setting-sources project --strict-mcp-config \
  --agents '{"avi": <~/.claude/agents/avi.md, inline>}' --agent avi --permission-mode dontAsk \
  --allowedTools "Read,Grep,Glob,Bash(grep *),Bash(ls *),Bash(cd *),Bash(<bin>/task note <slug> --comment *),..." \
  --add-dir /Users/alex/projects --name "intent-scout <slug>"
```

started from the hub primary with an allow-listed environment (no session ids, no
admin token), its output in `~/.intent-scout/<slug>.log` and its pid
in `<slug>.pid` beside it (the folder 0700, the files 0600). `dontAsk` denies
anything outside the allow-list rather than prompting. `--setting-sources project`
matters as much: without it the operator's `~/.claude/settings.json` allow rules
(git push, `gh pr merge`, `bin/task:*`) are ADDED under `dontAsk`, so Avi's
definition rides inline through `--agents`. The project source still loads the
hub's own `.claude/settings.json`, so `launch!` refuses (and `begin` prints the
manual block) when that file holds anything but read-only allow rules
(`IntentScout.project_settings_violations`; the tracked file is pinned by
`test/lib/intent_scout_project_settings_test.rb`). The note rule names the
scouted task and the `--comment` flag, so the scout cannot post on any other task,
nor post a handoff or qa-feedback note: `bin/task note` takes one note flag per
call, so a trailing `--handoff` is refused. The allow-list has no `git` and no
`rg`, whose `--output`, `-O` and `--pre` options write files or run programs; the
Grep tool searches instead. `script/intent_scout_permission_smoke.rb` proves all
of it against the real CLI (run by hand with `ruby script/intent_scout_permission_smoke.rb`; never in CI): `git add`,
`git show --output`, `rg --pre` and a note on another task are denied, and
`bin/task note` on the scouted task is allowed. Run
it after any change to the launch. It then
posts an `INTENT SCOUT OWED:` note carrying the pid, and prints, last:

```text
scout: Avi launched in the background (pid N, log PATH) - do not launch another; read the brief before submit: …
```

**Never both, never twice.** The pid file is created exclusively before the spawn,
so a second `begin` (a resume of a `building` task, or two racing) reports the
first launch instead of starting another; a resume never launches. `begin` prints
the paste-ready `Agent(subagent_type: "avi", …)` block instead, and the session
that ran it launches the scout, only when it could not launch: no `claude` CLI (a
Codex session), `INTENT_SCOUT_AUTO=0`, CI or the test suite, a failed spawn, or
five scouts already running (the cap below).

The scout counts toward the five-agent cap, but it runs no suite, so it never
counts as a certifying agent. A scout that exits within half a second of its launch
is a failed launch: begin prints the block instead of "launched".

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

   Use the Grep tool over `/Users/alex/projects/<repo>` (case-insensitive, with
   line numbers). A headless scout has no `git` or `rg` in its shell.

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
   newest such note back (exit 2 when none is there, exit 1 when the board could
   not be read), and `bin/submit` warns at 0/8 when none is on the task.

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
- `bin/lib/intent_scout.rb`: the marker, the auto-launch, the begin lines and the submit warning.
