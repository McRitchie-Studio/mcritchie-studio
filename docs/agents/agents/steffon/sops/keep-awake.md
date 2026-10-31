# Keep Awake
<!-- registry: one shared hold that keeps Alex McRitchie's Mac awake while agents work past him: start, renew, stop, status, back off -->

## Status: Active

This is Steffon's `keep-awake` SOP: the one way any agent keeps Alex McRitchie's
Mac awake while work runs past the time he is at it (an overnight release, a long
build, a slow review). It is the procedure; `bin/keep-awake` is the tool, at the
fixed path `/Users/alex/projects/.agents/bin/keep-awake` (the hub's
`bin/keep-awake` is the fallback).

There is one hold for the whole Mac, shared by every agent. Each agent that needs
the Mac awake is a **holder** with a 30-minute **lease** it renews. One supervisor
holds `caffeinate -dims` (display, idle, disk and system sleep) and a menu-bar
indicator, and lets go when the last lease is released or lapses. An agent that
dies stops renewing, so the Mac sleeps again on its own within 30 minutes.

## Run it

1. **Look first.** `keep-awake status` (add `--json` for a script). It exits 0
   only while a hold is live, and prints who holds it, why and until when.
2. **Start or join.** `keep-awake start --by <your soul or session> --reason "<why>"`.
   If a hold is already live this JOINS it as a second holder; it never starts a
   second caffeinate. Use a stable `--by` (your task slug or session id), since
   that name is how you renew and release.
3. **Renew every 30 minutes** while the work runs: `keep-awake start` again with the
   same `--by` (idempotent), or `keep-awake renew --by <you>`. `--for 2h` sets a
   longer lease, up to 12h, when you cannot renew (a single long command).
   `renew` exits 1 when your lease has already lapsed: run `start` again.
4. **Stop when done.** `keep-awake stop --by <you>`. The hold ends only when every
   holder has released or lapsed.
5. `keep-awake history` prints the log of starts, joins, renewals, releases and
   lapses.

## The back-off rule

- Never run a bare `caffeinate` of your own for this; join the shared hold.
  (The long-running services, `bin/dispatcher`, `bin/client-build-launcher` and the
  release cycle, keep their own `caffeinate -is -w <pid>`; that is separate and
  stays.)
- `status` sees only keep-awake leases. A service's own `caffeinate -is -w <pid>`
  does not show there or in the menu bar, so `status` exiting 1 means no shared
  hold, not that nothing at all keeps the Mac awake.
- `status` exits 0: someone holds the Mac. If your work needs it too, `start`
  joins; do not stop another agent's hold, and release only your own `--by`.
- `status` says `STALE` (live leases, dead supervisor): the Mac is not held.
  `start` re-arms it.

## What Alex McRitchie sees

- A cup icon in the menu bar with the latest expiry time. Its menu lists each
  holder, why, and until when. "Hide indicator" hides only the icon; the hold
  continues. The icon quits itself when the hold ends. It reads one state file
  and never touches the keychain or any credential.
- A macOS notification when a hold starts or someone joins, when a lease lapses
  without a renew, and when the hold ends and the Mac may sleep again.

## The limit: lid closed on battery

`caffeinate` cannot hold a lid-closed sleep on battery
([conductor-host.md](conductor-host.md#caffeinate-and-why-it-no-longer-keeps-the-box-awake)).
For an overnight run, the lid stays open or the Mac stays on power. If Alex
McRitchie is leaving, say so in your hand-back before he closes it.

## Where things live

| What | Where |
|---|---|
| The command | `bin/keep-awake`, library `bin/lib/keep_awake.rb` |
| The menu-bar indicator | `bin/lib/keep_awake_indicator.swift`, compiled with `swiftc` on first use |
| State, lock, log | `/Users/alex/projects/.agents/keep-awake/` (`state.json`, `state.lock`, `history.log`, `supervisor.log`) |
| Tests | `test/lib/keep_awake_test.rb`, `test/commands/keep_awake_command_test.rb` |

`history.log` uses the same UTC timestamps as
`/Users/alex/projects/.agents/op-reads.log`, so hold windows can be lined up
against 1Password stalls (the hypothesis being tested: `op` wedges when the Mac
idles or its display sleeps overnight).
