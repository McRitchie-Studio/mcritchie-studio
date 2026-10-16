# Agent Dispatcher
<!-- registry: the agent mailbox's always-on worker on Alex's Mac: install, verify, alerts, unblock -->

## Status: Active

This is Steffon's `agent-dispatcher` SOP. `bin/dispatcher` is the service that
answers the agent mailbox: every message routed to a soul in Discord is claimed,
answered by headless Claude on Alex's claude.ai subscription, and replied to,
with nobody running a heartbeat by hand. It runs under launchd on Alex's Mac.

It is Steffon's because every failure it has is an infrastructure failure: a Mac
asleep, a signed-out CLI, a usage limit, a stuck lease, a dead letter. Steffon
holds admin on the board and can clear each one.

How the mailbox works end to end:
[`agent-message-loop.md`](../../../system/agent-message-loop.md).

## Bare invocation: what "agent-dispatcher" alone does

Alex starts this SOP by saying only `agent-dispatcher`. Run this default, from
`/Users/alex/projects/mcritchie-studio`, without asking which mode he wants:

1. `bin/dispatcher status`.
2. Act on what it says:

   | Status | Do |
   |---|---|
   | `not installed` (exit 3) | [Install](#install-once-per-mac), then [Verify](#verify) |
   | `running` | [Verify](#verify) |
   | anything else (`not running`, `installed but not loaded`, `unknown`; exit 1) | Read the last lines of `~/Library/Logs/agent-dispatcher.log`, find the row in the [Unblock playbook](#unblock-playbook), apply it, then [Verify](#verify) |

   Run Verify steps 1 and 3 here. Its step 2 is a post only Alex can make, so it
   waits for step 3 below.

3. Report a health card:
   - the service status and pid;
   - the version and code digest from the log's last `start` line;
   - any pause and its reason (the log's last `paused until <T> (<reason>)` line);
   - messages waiting (`bin/agent-inbox list --status received`) and dead letters
     (`bin/agent-inbox list --status dead`; its rows carry no time, so date each
     with `bin/agent-inbox show <id>`);
   - the time of the last completed answer (the log's last `completed #N` line).

   Then ask Alex to post `@Xan what is building?` in `lobster-tank` (Verify
   step 2) and to tell you when it is in. When he says it is in, show that
   message with `bin/agent-inbox show <id>`: the ingest path, claim-to-completion
   time, reply link and notes saved.

Never start a second copy with `bin/dispatcher run` while the service is
installed: two dispatchers split the messages and nobody can tell which one
answered. `bin/dispatcher install`, `status` and `uninstall` are allow-listed in
Alex's `~/.claude/settings.json` and need no prompt; `bin/agent-inbox` and the log
reads are not allow-listed.

## The split: read this before running anything

**You decide nothing about delivery.** Claiming, leases, retries, the cap, the
pause and the alerts are code, under test, identical on every run. This SOP is
the same shape as Turf Monster's
[`live-score-watch`](../../turf_monster/sops/live-score-watch.md): the code does
the mechanics, the schedule sets the floor, and you judge only the anomalies.

| Deterministic: the code | Agentic: you |
|---|---|
| Long-polling the board for every routed soul (`config/agent_routes.yml`) | Installing it, once per Mac |
| One claim at a time per thread, oldest first; at most 5 answers at once | Reading an alert and choosing the playbook row below |
| Renewing each lease every 3 minutes while its answer runs | Signing Claude back in, or waking the Mac |
| Handing a message back without spending an attempt on a usage limit (at most 3 times per message, the board's cap), and pausing until the reset | Deciding whether a dead letter is re-queued or left dead |
| Pausing 5 minutes after a failed Claude run, 30 after a signed-out one | Escalating to Alex when the fix is his (his login, his Mac) |
| Stopping a run past its deadline (TERM, then KILL after 10 seconds; no renewal past 8 minutes; the message given back) | |
| Pinging the board every minute | |
| Restarting itself on new code, and the ship reinstalling it when its plist template changes ([Updates](#updates-nobody-reinstalls-it)) | |
| One Discord alert per incident, one recovery line (`AgentDispatcherAlertJob`) | |

If you find yourself claiming or completing a message by hand to "help", stop.
The dispatcher will take it on its next poll; a hand claim only competes with it.

## What runs where

| Piece | Where |
|-------|-------|
| The service | `bin/dispatcher run` (`bin/lib/agent_dispatcher.rb`), launchd label `studio.mcritchie.agent-dispatcher` |
| Its plist | Rendered from `config/launchd/studio.mcritchie.agent-dispatcher.plist` into `~/Library/LaunchAgents/` by `bin/dispatcher install` |
| Its log | `~/Library/Logs/agent-dispatcher.log`: ids and states only, never message text. A raised run adds its error class, its first backtrace line, and its error message's first line with every quoted span redacted, capped at 200 characters |
| The answer path | `AgentMailbox::Responder` in `bin/lib/agent_mailbox.rb`, shared with `bin/heartbeat` |
| Its ping and the alerts | `POST /api/v1/agent_dispatchers/ping`; `AgentDispatcherAlertJob` every minute on the worker dyno (`config/recurring.yml`) |
| Where alerts post | `discord.ops_channel_id` in `config/agent_routes.yml` (`lobster-tank` today), as the shared bot |
| What you watch | `/admin/agent_messages`: the dispatcher row (live, paused, silent) above the message list |

**Billing.** Claude runs as `claude -p --safe-mode --tools "" --output-format json`
under Alex's claude.ai login. Every child gets an allow-listed environment
(`AgentMailbox::CHILD_ENV_ALLOW`: the basics, the agent board's own names and
`HEROKU_API_KEY` for `bin/release status`), so no API key, auth token, base URL or
Bedrock/Vertex switch can reach Claude, including ones Anthropic adds later.

**What it reads from Claude.** Only what the model cannot write: the exit status,
stderr, and the JSON envelope's `is_error` and `api_error_status`. A usage limit
or a signed-out CLI is recognised in a failed run's error text, never in an
answer, so a Discord message that coaxes Claude into replying "usage limit
reached" is posted as an answer and changes nothing.

**Awake.** The dispatcher holds `caffeinate -is -w <its pid>` while it lives:
the Mac does not idle-sleep, and does not system-sleep on power. Closing the lid
sleeps it all the same, on power or on battery; that is the "Mac asleep" row
below.

## Install (once per Mac)

Run from the hub's primary checkout, which the release moves to the shipped
code. `bin/dispatcher install`, `status` and `uninstall` are allow-listed in Alex's
`~/.claude/settings.json` (added 2026-10-14), by bare name from the hub and by
the absolute path `/Users/alex/projects/mcritchie-studio/bin/dispatcher`, so
Steffon installs and repairs the service with no permission prompt. Nothing
else is: `install --if-changed` belongs to the ship, and `run` belongs to launchd. The dispatcher runs from the checkout it was installed from; `install`
refuses a task desk under `.worktrees/`, which is torn down after its task.

```bash
cd /Users/alex/projects/mcritchie-studio
claude auth status                    # authMethod must read claude.ai (not an API key)
bin/dispatcher install                # writes the plist, bootstraps it, prints status
bin/dispatcher status                 # studio.mcritchie.agent-dispatcher: running (pid N)
tail -n 20 ~/Library/Logs/agent-dispatcher.log
```

The log's first line names the worker, the souls and the version:
`start dispatcher-<host>-<pid>-<rand> serving xan on discord (cap 5, version <sha>, code <digest>)`.

`bin/dispatcher install` is safe to re-run: it unloads the running copy first.
If it prints `launchctl bootstrap failed`, run it again: the unload of the old copy
can still be finishing on the first try. Under launchd, `HEROKU_API_KEY` is not set,
so a soul whose action is `bin/release status` (avi) reports that action as failed
and answers from its role; only `xan` is routed today.

## Updates: nobody reinstalls it

A release needs no step from anyone, two mechanisms between them:

- **New code restarts it by itself.** At startup the dispatcher digests its own
  files: `bin/dispatcher`, every file it required from the repo
  (`bin/lib/agent_dispatcher.rb`, `agent_mailbox.rb`, `agent_api.rb`,
  `cli_arg_guard.rb` and what they load) and `config/agent_routes.yml`
  (`AgentMailbox::CodeFingerprint`). It re-reads the digest on the minute ping. A new
  digest seen on two checks in a row (so a checkout read half-way through a move
  cannot start a restart loop) logs one line,
  `code changed (<old> -> <new>); restarting on the new code: …`, stops claiming,
  lets the runs in flight finish up to their deadline, and exits 0. It keeps
  pinging every minute (state `stopping`) while it drains, so a drain longer than
  5 minutes raises no silent alert. launchd's
  `KeepAlive` (plain `true`; `SuccessfulExit=false` would leave a clean exit dead)
  starts it on the new code. A release that touches none of those files does not
  restart it, and a routing change in `agent_routes.yml` does.
- **The ship reinstalls it when the plist template changes.** After the production
  ship restores the primaries and syncs the agent docs, it runs the hub primary's
  `bin/dispatcher install --if-changed` (`bin/release.rb#refresh_dispatcher_service`).
  With no plist in `~/Library/LaunchAgents` it does nothing. Otherwise it renders
  the new template with the installed plist's own ruby and PATH (the ship's
  environment is not the shell that installed it) and reinstalls only when that
  differs from the installed file. It only warns; it never fails a ship. A
  reinstall boots the old job out, waits up to 100 seconds for it to leave (its
  90-second ExitTimeOut plus a margin), and tries the bootstrap 3 times. If none
  takes, it marks the plist (`<!-- bootstrap failed … -->` after `</plist>`), so
  the next ship sees a difference and tries again. The
  comparison is byte for byte, so a plist edited by hand or by a plist editor
  (sorted keys, tabs) reads as changed and is reinstalled once from the template,
  keeping its ruby and PATH; the ships after that find it current.
- **Locale.** launchd passes no locale, so the template sets `LANG` and `LC_ALL`
  to `en_US.UTF-8` (they reach `claude` and `bin/task` through
  `AgentMailbox::CHILD_ENV_ALLOW`), and `bin/dispatcher` forces UTF-8 itself
  before it reads a file (`bin/lib/process_encoding.rb`).

A SIGTERM during a restart's drain (a reinstall's `bootout`) still cuts the wait to
the 60-second grace. The service runs whatever the primary has checked out, so a
session that checks out a branch in the primary restarts it onto that branch's
code; leave the primary on `main`.

## Verify

1. `/admin/agent_messages` shows the dispatcher row **live**, pinged under a
   minute ago, serving the routed souls.
2. Post `@Xan what is building?` in `lobster-tank`. Within about a minute the
   reply lands in the channel, and the log shows
   `claimed #N for xan` then `completed #N (completed)`.
3. `bin/dispatcher status` exits 0.

## The alerts and what each means

`AgentDispatcherAlertJob` runs every minute on the hub. Each check posts one
alert when it starts failing and one line when it clears, never one a minute.
The incident history is the `agent_mailbox_incidents` table.

| Alert | Means | Do |
|-------|-------|----|
| `Agent dispatcher silent: no ping from bin/dispatcher on <host> for N min` | No dispatcher has pinged for 5 minutes. Before the first install this never fires | Playbook: **Mac asleep** or **service down** |
| `Agent mailbox: N routed message(s) waiting over 10 minutes; oldest is #id …` | A routed message has sat `received` for 10 minutes. If the text adds `paused until … (usage_limit)`, the dispatcher is waiting out a usage limit on purpose | Read the pause reason, then the matching row |
| `Agent dispatcher back` / `Agent mailbox clear` | The incident is over | Nothing |

With no bot token or no `ops_channel_id`, nothing is posted and the worker logs
`[agent-dispatcher] floor alert not posted (...)`.

The inbound Gateway listener is not on this floor alert. When it stands down to
protect the bot token (its IDENTIFY budget or Discord's `session_start_limit` is
spent), it writes one `ErrorLog` row, `discord gateway: IDENTIFY budget spent …`
or `… session_start_limit has N of M left …`, and the backstop poll keeps storing
messages every 10 minutes. Nothing to do unless it recurs: a recurrence means the
gateway is failing before READY, so read the worker log's
`[agent-messages] discord gateway` lines
([`agent-message-loop.md`](../../../system/agent-message-loop.md)).

## Unblock playbook

| Symptom | Check | Fix |
|---------|-------|-----|
| **Service down**: silent alert, Mac awake | `bin/dispatcher status`; the log's last lines | `bin/dispatcher install` restarts it. A crash loop shows in the log; launchd retries every 30 seconds |
| **Board auth**: silent alert, the log repeats `claim failed: … HTTP 401` or `no answer from https://mcritchie.studio (unreachable, or no agent token)` | The dispatcher authenticates as the rest of the agent CLI does (`bin/lib/agent_api.rb`): the shared token cache, minted from `AGENT_API_SECRET` (env, then the hub's `.env`, then 1Password) | Make the secret reachable without a prompt (the hub checkout's `.env`), then `bin/dispatcher install`. A single 401 heals itself: the client drops the cached token and mints a new one |
| **Mac asleep**: silent alert, nothing in the log since | The log's last timestamp | Wake the Mac or ask Alex to; the dispatcher resumes by itself and the recovery line posts |
| **Signed out**: messages waiting, the row reads `paused … (claude_signed_out)` | `claude auth status` must show `authMethod` `claude.ai` | Ask Alex to run `claude auth login` (his login). The pause lifts within 30 minutes; `bin/dispatcher install` restarts it at once |
| **Usage pause**: the row reads `paused until T (usage_limit)` | The log's `paused until` line | Nothing: the messages were handed back without spending an attempt and are answered after T. After 3 such refunds a message spends attempts like any other, so a long outage can dead-letter it (re-queue below). If waiting until T is wrong, tell Alex; only he can raise the plan |
| **Bootstrap failed: 5**: `bin/dispatcher install` (or the ship's refresh) printed `launchctl bootstrap failed: Bootstrap failed: 5: Input/output error`, and `bin/dispatcher status` reads `installed but not loaded` | Install already waited up to 100s for the old job to leave (`launchctl print gui/$(id -u)/studio.mcritchie.agent-dispatcher` fails once it has) and tried the bootstrap 3 times. The plist ends in a `<!-- bootstrap failed … -->` mark | The service is down and KeepAlive cannot revive a booted-out job. Run `bin/dispatcher install` from the hub checkout. The mark makes the next production ship's `install --if-changed` retry by itself, so nothing is stranded if nobody does |
| **Run overdue**: `paused … (run_overdue)`, the log's `the run passed its … deadline` | A Claude run that outlived its timeout and its KILL | Nothing for one; for a pattern, run the Claude command by hand (row below) |
| **Claude failing**: `paused … (claude_failed)` | The log's `releasing #N: the Claude run failed …` lines | Run the same command by hand: `echo hi \| claude -p --safe-mode --tools "" --output-format json`. Fix what it prints |
| **Answer run raising**: `paused … (answer_raised)`, the log's `#N raised <Class> at <file:line>` and `releasing #N: the answer run raised <Class>: <message>` | The error the release reason names and the line the log names. `invalid byte sequence in US-ASCII` means the process has no UTF-8 locale: the plist must carry `LANG` and `LC_ALL` = `en_US.UTF-8` (the template does; `bin/dispatcher install` from the hub checkout restores it) | Fix the cause; the pause keeps the message's other attempts. A dead-lettered one: re-queue below |
| **Stuck lease**: a message `claimed` with its lease long lapsed | `/admin/agent_messages`, Claim column | Nothing to do by hand: the next claim takes a lapsed lease back (or dead-letters it on attempt 3) |
| **Dead letter**: a message `dead` | Its timeline on `/admin/agent_messages/:id` (`dead_lettered` and its reason) | Fix the cause first. Then re-queue it on the hub, in the Heroku console: `AgentMessage.find(ID).update!(status: "received", attempts: 0, usage_refunds: 0, claimed_by: nil, lease_expires_at: nil)` |
| **Context failing**: the log repeats `releasing #N: could not read the message's context` | The board's `GET /api/v1/agent_messages/:id/context` (holder-only) | Treat it as **Board auth** or a hub outage. The dispatcher gives the message back rather than answer without the person's memory |
| **Reading one answer**: why did it say that? | `bin/agent-inbox show <id>`: `session`, `resume`, `run`, `reasoning` | Run the printed `cd ~/.agents/mailbox/<soul> && claude --resume <id>` on the Mac that answered. It is for reading only; the answer path never resumes |
| **Unrouted**: a reply to a kept message that named no soul | The row reads `unrouted` | Nothing: it addressed no agent. A message that addresses nobody is not stored at all. Routing changes go through `discord-bot-setup` |
| **Held**: someone asked why an agent did not answer, or the row reads `held` | `/admin/agent_messages?status=held` or `bin/agent-inbox list --status held`; the row's `held` event says why. The owner-only guard: the sender is not on `config/agent_answerers.yml`, so no claim will ever take it ([loop doc](../../../system/agent-message-loop.md), "Held") | Leave it, unless Alex wants it answered. To answer that one message: **Release and answer** on its page (admin), or `bin/rails agent_people:release MESSAGE=<id>` on the hub. To answer a sender for good: add them to the yml and ship it. Never flip the status by hand |

## Uninstall

```bash
bin/dispatcher uninstall              # unloads the service and removes the plist
```

The silent alert then fires after 5 minutes, once. Say so in the channel when
the stop is deliberate.

## Scope

This SOP runs the service. It does not change routing (that is
[`discord-bot-setup`](discord-bot-setup.md)), give a soul more actions, or
answer messages itself. `bin/heartbeat <soul> --channel discord` stays the manual
form of the same answer path, for a test or a one-off.
