# Tyrion — Runtime

How Tyrion plays real people and talks to them: on an isolated NUC of Alex's,
OpenClaw carries his Discord conversation, and his runner (`cyvasse`
`bin/tyrion`) plays his games on the site over the bot API. The bot API
(task `tyrion-bot-api`) and the runner (task `tyrion-runner`) are built; the
NUC setup is below.

## On the NUC

Two processes, both calling out only; nothing on the NUC listens.

| Process | What | Needs |
|---|---|---|
| OpenClaw, agent `tyrion` | Talks to people on Discord, with no tools | His workspace (`bin/openclaw-workspace tyrion ~/.openclaw/workspace-tyrion`, from a clone of `mcritchie-studio`), his own Discord bot token, the model key; config from `openclaw.json5.example` in this folder |
| `bin/tyrion` (cyvasse) | Plays his matches on the site and talks in their chat | A clone of `cyvasse`, Node 20+, `CYVASSE_BOT_TOKEN` (issued with `bin/rails "bot_tokens:issue[tyrion]"` on the server), optionally the model key and `npm install @anthropic-ai/sdk` in `script/tyrion` |

The NUC reaches three hosts: Discord, the model API and the Cyvasse site.
To refresh his character after a docs change, pull `mcritchie-studio` and
re-run `bin/openclaw-workspace`; it rewrites SOUL.md, AGENTS.md and
IDENTITY.md and leaves his memory alone.

## The shape

```text
 isolated machine (Alex's)                        cyvasse.mcritchie.studio
 ┌──────────────────────────────┐   HTTPS out    ┌─────────────────────────────┐
 │ tyrion runner (Node)         │ ─────────────▶ │ /api/bot/*  (bearer token,  │
 │  · poll inbox                │ ◀───────────── │  the tyrion account only)   │
 │  · setup from game.md        │                │ Match#set_up! / #play!      │
 │  · move: engine + his eval   │                │ LiveMatch stand-in if he is │
 │  · chat: soul + voice → LLM  │ ── HTTPS out ─▶│ silent (two missed clocks)  │
 └──────────────────────────────┘  model API     └─────────────────────────────┘
        no inbound port, no other secrets
```

### Poll, not webhook

A webhook needs something listening on Alex's machine that the internet can
reach: an open port or a tunnel. That is the one hole an isolated machine must
not have. So the runner **polls outward** instead: every two seconds while a
live game is on, every thirty when idle, it asks the server what needs doing.
A live move clock is 30 s and the in-app computer already takes 5-13 s to move
(`LiveMatch::BOT_PACING`), so a two-second poll costs nothing a player can see.

A literally air-gapped machine (no network at all) cannot play an online game.
The workable reading is an **isolated** one: outbound connections only (the
Cyvasse site, the model API and Discord), nothing inbound, nothing else
installed or signed in. The machine is a NUC running OpenClaw.

### If the runner is off

The server already has the answer: a live seat that misses two clocks is taken
over by the in-app computer for the rest of the match (`LiveMatch`
`STRIKES_TO_REPLACE`). Better still, the Play Now button can check the runner's
last poll and, if it is older than a minute, seat the in-app bot as `tyrion`
from the start, so nobody waits out two clocks for an absent player.

## The server side (cyvasse repo)

| Piece | What |
|---|---|
| `bot_tokens` | One row per token: user, a SHA-256 digest (the token itself is shown once, at creation), `last_used_at`, `revoked_at`. Created by a rake task an admin runs; revoked the same way |
| `Api::Bot::BaseController` | Bearer auth; refuses any user that is not a computer player; rate-limited; every call logged with the match id |
| `GET /api/bot/inbox` | His matches needing action: set up, his turn, and new chat messages since a cursor. Also stamps his heartbeat |
| `GET /api/bot/matches/:id` | `Match#state_for` from his seat (the opponent's army hidden until both are in, as for any player) |
| `POST /api/bot/matches/:id/setup` | A lineup, through `Match#set_up!` |
| `POST /api/bot/matches/:id/moves` | A whole turn, through `Match#play!`, which checks it by the engine's rules like any player's |
| `POST /api/bot/matches/:id/messages` | A chat line, through the ordinary message rules (1,000 characters, between the match's players) |
| `POST /api/bot/matches/:id/flag` | Marks a match for a human to read (abuse, threats) |
| Play Now | Seats `tyrion` as a remote player when his heartbeat is fresh, the in-app bot otherwise |

Everything he can do, any signed-in player can already do from a browser;
the API adds no power, only a door for one account.

## The runner

- **Node, importing the engine.** The rules' source of truth is plain ES
  modules (`app/javascript/cyvasse`) that already run under Node for
  `bin/test-js`. The runner lives beside them in the `cyvasse` repo
  (`script/tyrion/`) and imports them unchanged, so its legal moves are the
  server's legal moves by construction, and scores them with his evaluation
  ([`game.md`](game.md#the-numbers-for-the-runtime)), two plies deep to start.
- **Setups** from his five, chosen as [`game.md`](game.md#phase-by-phase) says.
- **Chat** through the model API with a system prompt built from
  [`soul.md`](soul.md) and [`voice.md`](voice.md), the last few chat lines,
  and a one-line summary of the board. The model has **no tools**: it returns
  text, and the runner decides whether to post it. Moves never come from the
  model.
- **Output filter** before any line is posted: 280 characters, no URLs, no
  email addresses, no string that matches anything in the runner's own
  environment, else the line is dropped and a stock one sent instead.

## The threat model

Alex's concern, in his words: nobody should be able to "squeeze my CC out of
him". There are two ways that could happen, and each has its own guard.

| Threat | Guard |
|---|---|
| **Talking a secret out of him** (prompt injection in chat) | He holds none. His prompt contains his soul and the game, no keys, no internals. The output filter drops any line containing the runner's own secrets or a URL. The Cyvasse token can only play his own games |
| **Running up the bill** (chatting endlessly to burn model credits: the real way to reach a card) | A dedicated model API key in its own workspace with a **hard monthly spend limit** (Discord chat through OpenClaw spends from the same key, so the limit covers both); the chat model set by `TYRION_CHAT_MODEL` (default `claude-opus-5-5` at low effort, the call Alex left to us), each line cut to 280 characters; at most one reply per opponent message, 20 replies per match, and a per-player daily cap, after which he plays on in silence. **Alex:** set the monthly cap |
| **The machine is stolen or compromised** | It holds three revocable things: the Cyvasse bot token (revoke with the rake task), his Discord bot token (reset in the Discord developer portal) and the capped model key (revoke in the console). Nothing else lives on it |
| **Talking him out of something on Discord** | The same answer as in match chat: he holds nothing, and his OpenClaw agent has no tools, so there is nothing to run, read or send |
| **The token leaks** | Worst case, someone plays Tyrion's games badly. Revoke and reissue |
| **Abuse in chat** | He stops talking and flags the match (`/flag`); admins read it on `/admin/matches/:id` |
| **Name and likeness** | Characters are George R. R. Martin's. The app already names its computer players after them; the portrait rule (original art, no likeness) stands, and he never quotes the books at length. **Alex:** if Tyrion becomes a marketing face rather than a table opponent, that is a legal question worth asking first |

## Build order

1. **cyvasse bot API** (task `tyrion-bot-api`) — tokens, the `/api/bot` endpoints, the heartbeat and
   the Play Now switch; backend shape, request tests for every refusal.
2. **Tyrion runner** (task `tyrion-runner`) — the Node program in
   `cyvasse/script/tyrion/`: setups, search, chat and filter. **Alex** may
   still prefer a separate repo for the isolated machine.
3. **Tune** — play him against the legacy bot and against people; adjust the
   weights in [`game.md`](game.md) from what he loses.
