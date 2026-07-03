# Atomic-capture PostToolUse hook

`bin/atomic-capture-hook` is the **Phase B live-capture** producer: a Claude Code
`PostToolUse` hook that streams every tool call into the atomic-capture endpoint,
so a fresh Claude Code session populates the per-action trajectory at
`/alex/heartbeat` **live** — one `AtomicAction` row per tool call.

It is the half-2 producer for the consumer half (the `/api/v1/atomic_actions`
endpoint, owned by the `atomic-capture-api-endpoint` task and `AtomicAction`
model). The hook only writes; the endpoint persists.

## What it does

On a `PostToolUse` event, Claude Code passes JSON on stdin:

```json
{ "session_id": "…", "transcript_path": "…", "cwd": "…",
  "hook_event_name": "PostToolUse", "tool_name": "Edit",
  "tool_input": { … }, "tool_response": { … } }
```

The hook maps that to the `AtomicAction.capture` contract and POSTs it (flat JSON,
matching the `/api/v1` convention) to
`${ATOMIC_CAPTURE_URL:-http://localhost:3000}/api/v1/atomic_actions`:

| Capture field | Source |
|---------------|--------|
| `session_id`  | event `session_id` (required — no id ⇒ no POST) |
| `kind`        | `tool_name` mapped: Read/Glob/Grep→`read`, Edit/Write/NotebookEdit→`edit`, Bash→`bash`, Task/Agent→`delegate`, WebFetch/WebSearch→`research`; **unknown→tool name downcased** |
| `input`       | `tool_input` serialized, **secret-redacted**, then truncated (~3 KB) |
| `output`      | `tool_response` serialized, **secret-redacted**, then truncated (~3 KB) |
| `outcome`     | `ok`, or `error` when `tool_response` carries an explicit failure signal (`error` / `is_error:true` / `success:false` / `interrupted:true`) — a noisy stderr is **not** a failure |
| `actor`       | `agent` |
| `model`       | the **session model** — see below (nil ⇒ key dropped, column stays null) |
| `occurred_at` | now (UTC ISO-8601) |
| `task_slug`, `stage`, `mascot` | the **active-feature marker** (see below) |

`tokens_in`/`tokens_out`/`cost` and `event_slug`/`result_slug`/`seq` are
**intentionally absent** — a hook can't know them; the model fills its defaults
and derives `seq` per session.

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

Two classes of Bash call are dropped **before** any POST — they own no narrated
span and would otherwise land in "Unlabeled":

- **Navigation** — a command whose first token is `cd` / `pushd` / `popd` / `pwd`
  (a bare directory move; ~84% of the raw noise).
- **Narration** — a command whose invocation **is** `bin/atomic-event` (the
  agent's self-narration CLI). It's the span machinery itself, so capturing the
  call that declares a span would double-record it as a raw action. Matches only
  an actual invocation — any path prefix (`/abs/…/bin/atomic-event`,
  `./bin/atomic-event`) and optional leading `ENV=val` assignments — never a
  command that merely *mentions* the string (`grep atomic-event`, `cat
  bin/atomic-event`, an edit to the file). A `cd … && bin/atomic-event` already
  drops as navigation (first token `cd`).

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
| `ATOMIC_CAPTURE_URL` | `http://localhost:3000` | capture endpoint base URL |
| `AGENT_API_SECRET` | — | agent secret; the hook mints a 24h token via `POST /api/v1/auth { secret }` |
| `CLAUDE_PROJECTS_DIR` | `~/projects` | where the session marker + token cache live |
| `ATOMIC_CAPTURE_FOREGROUND` | unset | `1` runs delivery inline (tests/debug) |

The agent token is sourced **exactly like `bin/task`**: `AGENT_API_SECRET` from
the environment, else 1Password (`op://agents/Agent API Secret/AGENT_API_SECRET`),
else the repo `.env`. The minted bearer token is then sent as
`Authorization: Bearer <token>` to `/api/v1/atomic_actions`.

## Install — `settings.json` snippet

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
            "command": "/Users/alex/projects/mcritchie-studio/bin/atomic-capture-hook",
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

> **Do not hand-edit the operator's global `~/.claude/settings.json` from a build
> session.** `bin/install-agent-docs` wires this hook idempotently (pointing at
> `$RUNTIME_ROOT/bin/atomic-capture-hook`, pruning stale worktree entries) the
> same way it wires the status line and SessionStart mascot hook. The orchestrator
> runs `bin/install-agent-docs` **after** this change is reviewed and merged.

## SessionEnd hook — close the last open span

The companion producer is the **SessionEnd** hook, which runs
`bin/atomic-event close-open` when a Claude Code session terminates. It closes any
span still open for the session (reading the session id off the SessionEnd stdin
payload) with a generic `session ended` outcome — so a session's **last** span
never hangs open forever and trailing actions never fall into "Unlabeled". It is
best-effort and always exits 0, exactly like the atomic-event narration CLI.

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
            "command": "/Users/alex/projects/mcritchie-studio/bin/atomic-event close-open",
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
> (pointing at `$RUNTIME_ROOT/bin/atomic-event close-open`, pruning stale worktree
> entries) the same way it wires the PostToolUse capture hook. The orchestrator
> runs it **after** this change is reviewed and merged.

## Tests

`test/lib/atomic_capture_hook_test.rb`:

- **[unit]** the pure builders — `tool_name`→`kind` mapping, truncation, outcome
  detection, marker derivation, and the full payload shape (loaded in process; the
  bin's main is guarded so `load` is side-effect free).
- **[integration]** the real script shelled out against a localhost stub HTTP
  server: it mints a token, then POSTs the right shape to `/api/v1/atomic_actions`
  with `Authorization: Bearer …`; a missing `session_id` posts nothing; a closed
  port still exits 0.
