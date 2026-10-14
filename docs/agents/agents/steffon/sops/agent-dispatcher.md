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

## The split: read this before running anything

**You decide nothing about delivery.** Claiming, leases, retries, the cap, the
pause and the alerts are code, under test, identical on every run. This SOP is
the same shape as Turf Monster's
[`live-score-watch`](../../turf_monster/sops/live-score-watch.md): the code does
the mechanics, the schedule sets the floor, and you judge only the anomalies.

| Deterministic: the code | Agentic: you |
|---|---|
| Long-polling the board for every routed soul (`config/agent_routes.yml`) | Installing it, once per Mac, after the release ships |
| One claim at a time per thread, oldest first; at most 5 answers at once | Reading an alert and choosing the playbook row below |
| Renewing each lease every 3 minutes while its answer runs | Signing Claude back in, or waking the Mac |
| Handing a message back without spending an attempt on a usage limit, and pausing until the reset | Deciding whether a dead letter is re-queued or left dead |
| Pausing 5 minutes after a failed Claude run, 30 after a signed-out one | Escalating to Alex when the fix is his (his login, his Mac) |
| Pinging the board every minute | |
| One Discord alert per incident, one recovery line (`AgentDispatcherAlertJob`) | |

If you find yourself claiming or completing a message by hand to "help", stop.
The dispatcher will take it on its next poll; a hand claim only competes with it.

## What runs where

| Piece | Where |
|-------|-------|
| The service | `bin/dispatcher run` (`bin/lib/agent_dispatcher.rb`), launchd label `studio.mcritchie.agent-dispatcher` |
| Its plist | Rendered from `config/launchd/studio.mcritchie.agent-dispatcher.plist` into `~/Library/LaunchAgents/` by `bin/dispatcher install` |
| Its log | `~/Library/Logs/agent-dispatcher.log`: ids and states only, never message text |
| The answer path | `AgentMailbox::Responder` in `bin/lib/agent_mailbox.rb`, shared with `bin/heartbeat` |
| Its ping and the alerts | `POST /api/v1/agent_dispatchers/ping`; `AgentDispatcherAlertJob` every minute on the worker dyno (`config/recurring.yml`) |
| Where alerts post | `discord.ops_channel_id` in `config/agent_routes.yml` (`lobster-tank` today), as the shared bot |
| What you watch | `/admin/agent_messages`: the dispatcher row (live, paused, silent) above the message list |

**Billing.** Claude runs as `claude -p --safe-mode --tools ""` under Alex's
claude.ai login. The dispatcher removes `ANTHROPIC_API_KEY` from itself and from
every child, so an exported API key can never be what pays.

**Awake.** The dispatcher holds `caffeinate -is -w <its pid>` while it lives:
the Mac does not idle-sleep, and does not system-sleep on power. Closing the lid
on battery still sleeps it; that is the "Mac asleep" row below.

## Install (once per Mac, after the release ships)

Run from the hub's primary checkout, which the release has moved to the shipped
code. The dispatcher runs from the checkout it was installed from.

```bash
cd /Users/alex/projects/mcritchie-studio
claude auth status                    # authMethod must read claude.ai (not an API key)
bin/dispatcher install                # writes the plist, bootstraps it, prints status
bin/dispatcher status                 # studio.mcritchie.agent-dispatcher: running (pid N)
tail -n 20 ~/Library/Logs/agent-dispatcher.log
```

The log's first line names the worker, the souls and the version:
`start dispatcher-<host>-<pid>-<rand> serving xan on discord (cap 5, version <sha>)`.

`bin/dispatcher install` is safe to re-run: it unloads the running copy first.
After a release that changes `bin/dispatcher` or its libraries, re-run it so the
service restarts on the new code.

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

## Unblock playbook

| Symptom | Check | Fix |
|---------|-------|-----|
| **Service down**: silent alert, Mac awake | `bin/dispatcher status`; the log's last lines | `bin/dispatcher install` restarts it. A crash loop shows in the log; launchd retries every 30 seconds |
| **Mac asleep**: silent alert, nothing in the log since | The log's last timestamp | Wake the Mac or ask Alex to; the dispatcher resumes by itself and the recovery line posts |
| **Signed out**: messages waiting, the row reads `paused … (claude_signed_out)` | `claude auth status` must show `authMethod` `claude.ai` | Ask Alex to run `claude auth login` (his login). The pause lifts within 30 minutes; `bin/dispatcher install` restarts it at once |
| **Usage pause**: the row reads `paused until T (usage_limit)` | The log's `paused until` line | Nothing: the messages were handed back without spending an attempt and are answered after T. If waiting until T is wrong, tell Alex; only he can raise the plan |
| **Claude failing**: `paused … (claude_failed)` | The log's `releasing #N: the Claude run failed …` lines | Run the same command by hand: `echo hi \| claude -p --safe-mode --tools ""`. Fix what it prints |
| **Stuck lease**: a message `claimed` with its lease long lapsed | `/admin/agent_messages`, Claim column | Nothing to do by hand: the next claim takes a lapsed lease back (or dead-letters it on attempt 3) |
| **Dead letter**: a message `dead` | Its timeline on `/admin/agent_messages/:id` (`dead_lettered` and its reason) | Fix the cause first. Then re-queue it on the hub, in the Heroku console: `AgentMessage.find(ID).update!(status: "received", attempts: 0, claimed_by: nil, lease_expires_at: nil)` |
| **Unrouted**: a message that named no soul | The row reads `unrouted` | Nothing: it addressed no agent. Routing changes go through `discord-bot-setup` |

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
