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
| `input`       | `tool_input` serialized + truncated (~3 KB) |
| `output`      | `tool_response` serialized + truncated (~3 KB) |
| `outcome`     | `ok`, or `error` when `tool_response` carries an explicit failure signal (`error` / `is_error:true` / `success:false` / `interrupted:true`) — a noisy stderr is **not** a failure |
| `actor`       | `agent` |
| `occurred_at` | now (UTC ISO-8601) |
| `task_slug`, `stage`, `mascot` | the **active-feature marker** (see below) |

`tokens_in`/`tokens_out`/`cost` and `event_slug`/`result_slug`/`seq` are
**intentionally absent** — a hook can't know them; the model fills its defaults
and derives `seq` per session.

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

## Tests

`test/lib/atomic_capture_hook_test.rb`:

- **[unit]** the pure builders — `tool_name`→`kind` mapping, truncation, outcome
  detection, marker derivation, and the full payload shape (loaded in process; the
  bin's main is guarded so `load` is side-effect free).
- **[integration]** the real script shelled out against a localhost stub HTTP
  server: it mints a token, then POSTs the right shape to `/api/v1/atomic_actions`
  with `Authorization: Bearer …`; a missing `session_id` posts nothing; a closed
  port still exits 0.
