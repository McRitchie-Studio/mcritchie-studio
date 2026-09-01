# Atomic-capture hooks (PreToolUse + PostToolUse)

`bin/atomic-capture-hook` is the **Phase B live-capture** producer: a Claude Code
or Codex `PostToolUse` hook that streams every tool call into the
atomic-capture endpoint, so a fresh agent session populates the per-action
trajectory at `/alex/heartbeat` **live** - one `AgentAction` row per tool call.

It is the half-2 producer for the consumer half (the `/api/v1/agent_actions`
endpoint and `AgentAction` model). The hook only writes; the endpoint persists.
The legacy `/api/v1/atomic_actions` route remains a compatibility alias, but new
docs and installs should point at `/api/v1/agent_actions`.

## What it does

On a `PostToolUse` event, Claude Code passes JSON on stdin:

```json
{ "session_id": "…", "transcript_path": "…", "cwd": "…",
  "hook_event_name": "PostToolUse", "tool_name": "Edit",
  "tool_input": { … }, "tool_response": { … } }
```

The hook maps that to the `AgentAction.capture` contract and POSTs it (flat JSON,
matching the `/api/v1` convention) to
`${ATOMIC_CAPTURE_URL:-https://mcritchie.studio}/api/v1/agent_actions`.

Codex uses a different shape (`thread_id` plus function-call transcript rows
under `~/.codex/sessions/**/<thread>.jsonl`). The hook normalizes that provider
shape first:

- `thread_id`/`id`/`CODEX_THREAD_ID` become the canonical `session_id`.
- `exec_command` and `write_stdin` become `Bash`; `apply_patch` becomes `Edit`;
  read-like MCP/resource tools become `Read`; `tool_search_tool` becomes
  `WebSearch`; unmapped function names still capture under their own kind.
- If the hook payload does not include the tool input/output, the newest paired
  `function_call` + `function_call_output` is recovered from the Codex transcript.
- Codex `last_token_usage` is stamped as fresh `tokens_in`/`tokens_out` with
  `cached_input_tokens` carried separately as `cache_read_tokens`.

The canonical capture fields are:

| Capture field | Source |
|---------------|--------|
| `session_id`  | Claude `session_id`, Codex `thread_id`/`CODEX_THREAD_ID` (required — no id ⇒ no POST) |
| `kind`        | `tool_name` mapped: Read/Glob/Grep→`read`, Edit/Write/NotebookEdit→`edit`, Bash→`bash`, Task/Agent→`delegate`, WebFetch/WebSearch→`research`; **unknown→tool name downcased** |
| `input`       | `tool_input` serialized, **secret-redacted**, then truncated (~3 KB) |
| `output`      | `tool_response` serialized, **secret-redacted**, then truncated (~3 KB) |
| `summary`     | the action's goal slug, **pattern-redacted** (like `input`/`key_method`). Bash → the call's `description` param (the goal the agent wrote); every **other tool synthesizes** a label from its most meaningful param — Read/Edit/Write/NotebookEdit → `<Tool> <file basename>`, Grep → `Grep "<pattern>"`, Glob → `Glob <pattern>`, Task/Agent (delegate) → the `description` param, WebFetch → `WebFetch <url>`, WebSearch → `WebSearch "<query>"`, AskUserQuestion → the first question's header; a missing param / unmapped tool ⇒ absent |
| `key_method`  | **Bash only** — the call's `command` (the copy-and-rerun line on the heartbeat rows), **same redaction policy as `input`**; other tools ⇒ absent |
| `key_method_lang` | `bash` when `key_method` is present (the UI's language badge) |
| `outcome`     | `ok`, or `error` when `tool_response` carries an explicit failure signal (`error` / `is_error:true` / `success:false` / `interrupted:true`) or a Codex tool-result status header reports `Process exited with code N` where `N != 0` — a noisy stderr or echoed output text is **not** a failure |
| `actor`       | `agent` |
| `model`       | the **session model** — see below (nil ⇒ key dropped, column stays null) |
| `occurred_at` | now (UTC ISO-8601) |
| `task_slug`, `stage`, `mascot` | the **active-feature marker** (see below) |
| `agent_activity_id` | the open activity marker written by `bin/agent-activity` / `bin/atomic-event` |
| `tokens_in`, `tokens_out`, `cache_read_tokens`, `source_turn_uuid` | newest assistant turn usage + UUID from the session transcript, when available |

`cost` and `event_slug`/`result_slug`/`seq` are **intentionally absent** - a hook
can't know them; the model fills its defaults and derives `seq` per session.

### Secret redaction (never ship a secret off the box)

`input`/`output` are the **only** source of the captured tool I/O, and they render
on the **public** `/alex/heartbeat` surface — so the hook redacts **at the source**,
before the POST, so a secret never leaves the machine. Two layers:

- **Whole-field suppression** when the call touches secret **material** — a Bash
  command that prints a secret (`bin/secret`, `op read`, `printenv`, `gh auth
  token`, `heroku config`, `cat`/`head` of a `.env` / `credentials` / `*.pem` /
  `*.key` / `id_rsa`), or a Read/Write/Edit of a secret **file path**. A bare value
  (e.g. `bin/secret` output) has no key to pattern-match, so the whole field
  becomes `[redacted: secret material]`.
- **Pattern redaction** on whatever survives — `KEY=VALUE` / `KEY: VALUE` /
  `"KEY":"VALUE"` pairs whose key names a secret (`*SECRET*`, `*TOKEN*`,
  `*PASSWORD*`, `*_KEY`, `*CREDENTIAL*`, `*WEBHOOK*`, `*MNEMONIC*`, …) have the
  **value** masked (key kept, so the trajectory stays legible), plus standalone
  credential formats (PEM private-key blocks, `sk_live`/`sk_test`, `AKIA…`,
  `ghp_`/`github_pat_`, `xox…`, `Bearer …`). The JSON `"KEY":"VALUE"` form is
  covered because `tool_input`/`tool_response` are JSON-serialized before redaction,
  so a **structured** tool response (an MCP tool, a nested hash) with a secret-named
  key is caught too.

Redaction runs **before** truncation, so a secret near the ~3 KB cut can't survive
as a prefix. This is defense at the producer; broadening who can *read* the (now
secret-free) telemetry is a separate concern.

> **Best-effort, not a guarantee.** Pattern redaction catches secrets that carry a
> recognizable **key** or **format**. A **bare, space-separated value with no key
> and no known format is NOT caught** — e.g. `echo $SECRET`, `--password <val>`,
> `cut -d= .env`, a raw `op read` value, a Solana keypair `*.json` byte-array, or
> creds embedded in a `DATABASE_URL`. The **whole-field suppression** layer is the
> backstop for the common cases (secret-reader commands + secret file reads); the
> "never ship a secret off the box" headline holds for those, but a novel bare-value
> path can still slip. Widening coverage (keypair reads, URL creds) is tracked as a
> follow-up.

### What it DROPS (never a row)

A Bash call is dropped **before** any POST only when it is pure overhead - it
owns no narrated activity and would otherwise land in "Unlabeled". The decision
is made per shell segment (splitting the command on `&&`, `||`, `;`, `|`, `&`,
and newlines): the call drops only when every segment is overhead.

- **Navigation** - a segment whose first token is `cd` / `pushd` / `popd` / `pwd`
  (a bare directory move; ~84% of the raw noise).
- **Narration** - a segment whose invocation **is** `bin/agent-activity` or its
  compatibility alias `bin/atomic-event`. It's the activity machinery itself, so
  capturing the call that declares an activity would double-record it as a raw
  action. Matches only an actual invocation segment - any path prefix
  (`/abs/.../bin/agent-activity`, `./bin/atomic-event`) and optional leading
  `ENV=val` assignments - never a command that merely *mentions* the string
  (`grep atomic-event`, `cat bin/atomic-event`, an edit to the file).

Because the rule is per-segment, a compound call that mixes overhead with real
work is captured, never dropped: `cd /repo && git commit` keeps the commit, and
`bin/agent-activity next && bin/task update ...` keeps the update. Only a
fully-overhead call drops: a bare `cd`, a chain of directory moves,
`bin/agent-activity start`, or `cd /repo && bin/agent-activity next` (navigation
+ narration, no work). This is the deterministic guarantee - every substantive
tool call becomes a row, never silently eaten by a leading `cd` (the historical
first-token rule dropped `cd X && <work>` whole; that was the bug). The split is
quote-naive and biased to keep, so a separator inside a quoted string can only
cause an extra captured row, never a dropped one.

The hook also reads the local per-session open-activity marker written by
`bin/agent-activity` and stamps `agent_activity_id` on the payload. That pins the
action to the activity open at tool-call time instead of relying on whatever the
server finds open when the async POST arrives.

### Model derivation — what's actually available to the hook

Claude Code does **not** put the session model in the PostToolUse stdin payload,
and there is **no** documented model env var (verified against the hooks
reference + a live session: the payload is `session_id`, `prompt_id`,
`transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `tool_name`,
`tool_input`, `tool_response`; hook env carries only `CLAUDE_PROJECT_DIR` /
`CLAUDE_PLUGIN_*` / `CLAUDE_ENV_FILE`). The model **is** available one hop away:
the payload's `transcript_path` points at the session JSONL, whose **assistant**
lines each carry `message.model` (e.g. `claude-opus-4-8`). So the hook:

1. uses a direct `model` / `message.model` field if a future Claude Code adds one;
2. else reads the newest assistant `message.model` from a **bounded tail**
   (`TRANSCRIPT_TAIL_BYTES` ≈ 128 KB off the END — at PostToolUse time the last
   written line is almost always the assistant turn that issued the tool call, so
   this finds the model without reading a multi-MB file per call);
3. else leaves it nil — the capture endpoint drops the key and the column stays
   null. We only ever stamp a **real** model; nothing is fabricated.

Codex model/usage comes from the newest transcript `event_msg` token-count row.
The hook prefers `last_token_usage` for per-action spend and falls back to
`total_token_usage` only when needed. `cached_input_tokens` is not counted as
fresh input; it is stored as `cache_read_tokens` so server-side cost can price it
at the cache-read tier.

### Marker derivation

`task_slug` / `stage` / `mascot` come from the same active-feature marker
`bin/statusline` and `bin/agent-marker` read, in priority order:

1. the nearest `.agent-context.json` walking **up** from the event `cwd` (the
   worktree desk — uses `task_record_slug`/`task_slug`, `stage`, `mascot`);
2. else the per-session marker `${CLAUDE_PROJECTS_DIR:-~/projects}/.agents/sessions/<session_id>.json`.

No marker (pre-task session) ⇒ those three are null; capture still proceeds (the
model allows a null `task_slug`).

## Non-blocking by design — telemetry never breaks the work it observes

- **Always exits 0.** Every error is swallowed; no exception escapes.
- **Network leg runs in a detached child** (`fork` + `setsid`), so the parent
  returns in tens of ms and the session never waits on HTTP. Set
  `ATOMIC_CAPTURE_FOREGROUND=1` to run inline (the integration test does); a
  fork-less platform falls back to inline automatically.
- **Short HTTP timeouts** (~1–2 s open/read) so an unreachable endpoint fails fast.
- **24h token cached on disk** at `<projects>/.agents/atomic-capture/token.json`,
  so `op read` runs at most ~once/day, never per tool call.

## Environment / auth

| Var | Default | Purpose |
|-----|---------|---------|
| `ATOMIC_CAPTURE_URL` | `https://mcritchie.studio` | capture endpoint base URL |
| `AGENT_API_SECRET` | — | agent secret; the hook mints a 24h token via `POST /api/v1/auth { secret }` |
| `CLAUDE_PROJECTS_DIR` | `~/projects` | where the session marker + token cache live |
| `ATOMIC_CAPTURE_FOREGROUND` | unset | `1` runs delivery inline (tests/debug) |

The agent token is sourced **exactly like `bin/task`**: `AGENT_API_SECRET` from
the environment, else the repo `.env`, else — LAST — 1Password (the agent vault's
`Agent API Secret/AGENT_API_SECRET`). The vault is last because its reads are
metered against a 1,000/day cap shared by every lane, and the `.env` holds the
same secret for free on any provisioned machine; it stays in the chain for a
fresh machine mid-bootstrap, which has no `.env` yet. The minted bearer token is then sent as
`Authorization: Bearer <token>` to `/api/v1/agent_actions`.

## Install — hook snippets

The hook command must point at the **primary checkout** (`bin/atomic-capture-hook`),
not a worktree, so it survives worktree cleanup. Add to `~/.claude/settings.json`:

```jsonc
{
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ATOMIC_CAPTURE_URL=https://mcritchie.studio /Users/alex/projects/mcritchie-studio/bin/atomic-capture-hook",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

No `matcher` ⇒ it fires for every tool. (A `"matcher": "Read|Edit|Write|Bash"`
would scope it.)

## PreToolUse hook — the turn-driven span lifecycle

The **PreToolUse** hook is the companion producer that OPENS activity spans
automatically, so agents no longer hand-narrate every boundary. On each tool call it
reads the assistant turn (uuid + preamble text) and POSTs to
`/api/v1/agent_activities/turn_open`, which opens — or continues — the span for that
turn:

- **Reason live, before the tool runs** — the span opens at PreToolUse (not Post), so
  a hung / long-running action shows as an open, unsealed span ("I can see it started").
- **Idempotent per turn** — a turn's parallel tool calls share ONE span (the
  `(session_id, turn_uuid)` partial-unique index); the 2nd..Nth calls are no-ops.
- **Outcome at the seam** — the next turn's preamble lead sentence seals the prior
  span's outcome (`AgentActivity.split_preamble`); the rest is the new span's reason.
- **Genesis** — a session's first span opens as "A wild &lt;mascot&gt; appeared".
- **Nesting** — a subagent turn (same session, different transcript) nests under the
  delegating span via `parent_span_id`, and its transcript-scoped lane keeps it from
  sealing the parent's open Delegate span.

This SUPERSEDES manual narration: `bin/agent-activity start/next` become OVERRIDE-ONLY
(merge/split/annotate a derived span by hand). **To revert to fully-manual narration,
remove this PreToolUse block** — the whole auto-lifecycle is that one wiring switch.

Add to `~/.claude/settings.json` (command points at the **primary checkout**):

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ATOMIC_CAPTURE_URL=https://mcritchie.studio /Users/alex/projects/mcritchie-studio/bin/atomic-capture-hook",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

> **Do not hand-edit the operator's global `~/.claude/settings.json` from a build
> session.** `bin/install-agent-docs` wires this hook idempotently (pointing at
> `$RUNTIME_ROOT/bin/atomic-capture-hook`, pruning stale entries) the
> same way it wires the status line and SessionStart mascot hook. The orchestrator
> runs `bin/install-agent-docs` **after** this change is reviewed and merged.

Codex gets the same producer in `/etc/codex/requirements.toml` when writable, or
in `~/.codex/hooks.json` as a user fallback:

```toml
[[hooks.PostToolUse]]

[[hooks.PostToolUse.hooks]]
type = "command"
command = "ATOMIC_CAPTURE_URL=https://mcritchie.studio /Users/alex/projects/mcritchie-studio/bin/atomic-capture-hook"
timeout = 5
statusMessage = "Capturing action"
```

## SessionEnd hook — close the last open activity

The companion producer is the **SessionEnd** hook, which runs
`bin/agent-activity close-open` when a Claude Code session terminates. It closes any
activity still open for the session (reading the session id off the SessionEnd stdin
payload) with a generic `session ended` outcome — so a session's **last** activity
never hangs open forever and trailing actions never fall into "Unlabeled". It is
best-effort and exits 0 on every narration OUTCOME, exactly like the activity
narration CLI — including the outcomes that record nothing (no session id, an
unknown `--category`, a failed POST, any swallowed error). The ONE exception,
since /tasks/atomic-event-help-mutates, is a command line the CLI cannot account
for: an unrecognized argument REFUSES with exit 2 and `--help` answers with usage
and exit 0, both without acting. That refusal is deliberate — `close-open --help`
used to close every open activity and delete three session markers — and it is
invisible to this hook, whose command line carries no flags.

Add to `~/.claude/settings.json` (command points at the **primary checkout** so it
survives worktree cleanup; **no `matcher`** ⇒ it fires for every end reason —
`clear`, `resume`, `logout`, `prompt_input_exit`, `bypass_permissions_disabled`,
`other`):

```jsonc
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ATOMIC_CAPTURE_URL=https://mcritchie.studio /Users/alex/projects/mcritchie-studio/bin/agent-activity close-open",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

> **Same rule — do not hand-edit the operator's global settings from a build
> session.** `bin/install-agent-docs` wires this SessionEnd hook idempotently
> (pointing at `$RUNTIME_ROOT/bin/agent-activity close-open`, pruning stale
> entries) the same way it wires the PostToolUse capture hook. The orchestrator
> runs it **after** this change is reviewed and merged.

Codex uses `Stop` for the same teardown:

```toml
[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "ATOMIC_CAPTURE_URL=https://mcritchie.studio /Users/alex/projects/mcritchie-studio/bin/agent-activity close-open"
timeout = 5
```

## Fan-out token reconciliation — attributing child subagent spend

An activity's tokens/cost are normally a **transcript-delta** measured LIVE at its
close against the **parent** `~/.claude/projects/*/<sid>.jsonl` only. That is correct
for a solo session, but in a **supervisor + subagents** session (e.g. `pr-review`,
where Avi spawns reviewers) it breaks: after the first delegation the parent
transcript goes **quiet**, and the real spend moves into **child** transcripts at
`~/.claude/projects/<proj>/<sid>/subagents/agent-<id>.jsonl` (each with a sibling
`.meta.json` naming its `agentType`/soul + spawn tree). Nothing read those, so every
post-delegation activity measured a **zero** parent delta and rendered `—` — the
"token attribution stops after fan-out" bug (proven on prod session `84293426`:
parent 147k in vs. seven children ~1.9M in).

`bin/agent-activity reconcile [--session <id>]` fixes it. It:

1. `GET /api/v1/agent_activities/windows?session_id=<sid>` — the session's activity
   windows (id, agent lane, `opened_at`/`closed_at`), which the board knows and the
   local reconciler needs.
2. reads the local child `subagents/*.jsonl` transcripts (which the board can't see)
   via `lib/agent_fanout_usage.rb`, and
3. `POST /api/v1/agent_activities/reconcile` — the computed per-activity usage, which
   the board stamps (session-scoped: a token can never patch another session's rows).

**Attribution model — per-AUTHOR partition.** Each activity is measured against the
transcript of the agent that AUTHORED it: the parent for the root session's own
turns, each subagent's child transcript for the activities it narrated (a reviewer's
own review; the supervisor's nil-lane orchestration, which falls back to the nil lane
because its soul has no soul-lane activity). Every **distinct** assistant turn (deduped
by `message.id` — one API turn is serialized once per content block, all copies
carrying the same usage, so a naive sum multiplies it) is assigned to exactly ONE
activity: the one open in the turn's lane at the turn's timestamp. Summing per
activity therefore **partitions** the whole trajectory's spend (parent + every child)
across the rows — no double-count. Turns after the last lane-activity closed are
unnarrated orphans, dropped (the "Unlabeled" analog).

**Wiring.** `bin/agent-activity close-open` (the SessionEnd/Stop hook above) runs
`reconcile` **after** the teardown close, so a slow child-transcript read can never
leave an activity hanging open; any session can be backfilled by hand with
`bin/agent-activity reconcile --session <id>`. A plain (non-fan-out) session has no
child transcripts, so reconcile is a no-op and never disturbs its live measurements.

> **Known limitation.** When ONE soul runs multiple CONCURRENT subagents mapped to
> multiple concurrent same-lane activities, the lane+timestamp partition splits their
> spend by wall-clock window rather than per-subagent — still an exact partition (no
> double-count), just not per-review-precise. A `toolUseId`/span-overlap child→activity
> match is a documented follow-up.

## Tests

`test/lib/atomic_capture_hook_test.rb`:

- **[unit]** the pure builders — `tool_name`→`kind` mapping, truncation, outcome
  detection, provider-adapter normalization, Codex transcript recovery, marker
  derivation, and the full payload shape (loaded in process; the bin's main is
  guarded so `load` is side-effect free).
- **[integration]** the real script shelled out against a localhost stub HTTP
  server: it mints a token, then POSTs the right shape to `/api/v1/agent_actions`
  with `Authorization: Bearer …`; a missing `session_id` posts nothing; a closed
  port still exits 0.

---

## Feed-forward: `bin/session-insights` (SessionStart) — closing the loop

The capture hook + narration record the trajectory; grading distills it into the
**Insight Bank** (`ActionGrade.banked`). `bin/session-insights` is the loop's
**output** stage — a **SessionStart** hook that reads the bank and injects the
curated lessons into a **fresh** agent's context, so a new session hatches already
knowing what past sessions learned (the OPSD feed-forward: banked lessons stop
being write-only).

**What it does.** It `GET`s `/api/v1/insights?limit=N` (bearer-gated, the curated
`ActionGrade.banked` newest-first, capped 1..50; default 12), then prints the
SessionStart context-injection JSON to stdout and exits 0:

```json
{ "hookSpecificOutput": { "hookEventName": "SessionStart",
    "additionalContext": "## Insights from past sessions — the McRitchie learning loop\n… ✓ do / ✗ avoid lines …" } }
```

Same board + token as the rest of the stack (`ATOMIC_CAPTURE_URL`,
`AGENT_API_SECRET` → repo `.env` → 1Password last, reusing the shared token cache).
**NON-FATAL by construction:** no token, an unreachable board, or an empty bank
prints **nothing** and exits 0 — the hook can never block or slow a session start.
`bin/session-insights` is tracked executable (`100755`) because the hook invokes
it as a bare path.

**Wiring — `bin/install-agent-docs` owns it.** As of the *wire-bank-to-session-bridge*
task the installer registers this hook idempotently, exactly like the capture +
SessionEnd hooks: it points the command at `$RUNTIME_ROOT/bin/session-insights`
(survives worktree cleanup), prunes stale `/.worktrees/.../bin/session-insights`
copies, appends only when absent, and bakes `ATOMIC_CAPTURE_URL` (default
`https://mcritchie.studio`, overridable via `AGENT_INSIGHTS_BOARD_URL`) so the
injected lessons are the curated **prod** bank. The wired Claude `settings.json`
entry:

```json
{ "hooks": { "SessionStart": [ { "hooks": [
  { "type": "command", "timeout": 15, "statusMessage": "Loading insights…",
    "command": "ATOMIC_CAPTURE_URL=https://mcritchie.studio /Users/alex/projects/mcritchie-studio/bin/session-insights" }
] } ] } }
```

(Claude hook `timeout` is in **seconds** — 15 comfortably covers the token-cache
warm path, with the bin's own 2s connect / 4s read timeouts bounding the cold one.)

**Codex** gets the same hook as a **second** `[[hooks.SessionStart.hooks]]` entry
beside the mascot — in the managed requirements (`/etc/codex/requirements.toml`)
and, when `/etc` needs admin, the `~/.codex/hooks.json` user fallback. It reuses
the same `hookSpecificOutput.additionalContext` schema; live consumption depends
on the McRitchie-patched Codex runtime (the patch targets hook output — confirm
with `bin/codex-update plan` before relying on Codex-side injection).

> **Activation still needs a fresh session.** Editing `~/.claude/settings.json`
> mid-session can silence hooks for the *running* session, so after this merges the
> orchestrator runs `bin/install-agent-docs` and verifies the injection in a **new**
> session (not the one that ran the installer). Relevance ranking by app/shape is a
> documented follow-up — v1 injects the most recently curated set.

### Tests

`test/lib/session_insights_test.rb`:

- **[unit]** the pure formatter — `insight_line` (✓ do / ✗ avoid, provenance,
  symbol/string keys, empty without a slug) and `additional_context` (header +
  rows; empty when nothing renders).
- **[integration]** the real script shelled out against a localhost stub: it mints
  a token, `GET`s the insights, and prints valid SessionStart injection JSON; an
  empty bank prints nothing and exits 0.

`test/commands/install_agent_skills_test.rb` covers the **wiring**:

- **[unit]** the bin is tracked executable (`100755`) and the installer source
  wires the hook under `SessionStart` with a prod-defaulted `ATOMIC_CAPTURE_URL`.
- **[integration]** installing lands one prod-targeted `SessionStart` insights hook
  (Claude + Codex managed requirements + user fallback), is idempotent across
  re-runs, honors `AGENT_INSIGHTS_BOARD_URL`, and prunes stale worktree copies.
