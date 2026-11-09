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
6. **Read the 1Password watch.** `status` also prints `op probe:` (the last probe:
   its time, `ok`, `hung` or `fail:<exit>`, how long it took, and how long the user
   had been idle) and, after any hang, `op hang:` (the window, and whether `op`
   answered again). You do nothing to run it; the supervisor runs it.

## The 1Password watch

On 2026-11-09 every `op` call hung from 03:41 to 07:29 MST, even
`OP_CACHE=false op whoami` with the service-account token. The Mac was awake and
held, but nobody had touched it since 03:30. The cause is not proven. The watch
collects the evidence.

- While a hold is live, the supervisor runs one `op whoami` with `OP_CACHE=false`
  about every 25 minutes, the renewal cadence. It probes when it starts, then on
  that cadence. While `op` hangs it probes every 5 minutes, so the window's edges
  are tight.
- Each probe has 20 seconds. It runs in its own process group, and at the
  deadline the supervisor kills that group: the probe's own process, nothing
  else. There is no retry.
- Each probe writes one row to `op-probe.log`: the UTC time, `ok`, `hung` or
  `fail:<exit>`, the seconds it took, the user-idle seconds (from `ioreg -c
  IOHIDSystem`, `HIDIdleTime`; `-` when unknown), and the supervisor pid.
- Each probe is also metered in `op-reads.log` (action `whoami`, via
  `keep-awake`; a hang is `timeout`), so `bin/op-reads` counts it. `op whoami`
  was measured on 2026-10-24 to spend no quota; budget one read per probe anyway,
  about 58 a day of holding. The supervisor probes, not `renew`, so more holders
  do not cost more reads, `renew` never waits on `op`, and the probe runs on
  schedule even when a holder forgets to renew.
- The probe uses the token of the shell that ran `keep-awake start`. With no
  token, `op` answers "not signed in" and the row reads `fail:<exit>`, not `hung`.
- A hang proven longer than 10 minutes (the first and last hung probes at least
  10 minutes apart) posts one macOS notification that names the window. One note
  per window; `op-probe.noted` remembers it across a supervisor restart.
- A probe that fails in any way never ends the hold.

What to do with a hang: read `keep-awake status` and `bin/op-reads`, and compare
the window with the user-idle seconds and `pmset -g log`. The fix for a stuck
`op` is the one `bin/lib/op_meter.rb` prints (`HUNG_LINE`): quit and reopen the
1Password app, and reboot if that fails.

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
- One macOS notification when `op` has hung for more than 10 minutes, naming the
  window (see [The 1Password watch](#the-1password-watch)).

## The limit: lid closed on battery

`caffeinate` cannot hold a lid-closed sleep on battery
([conductor-host.md](conductor-host.md#caffeinate-and-why-it-no-longer-keeps-the-box-awake)).
For an overnight run, the lid stays open or the Mac stays on power. If Alex
McRitchie is leaving, say so in your hand-back before he closes it.

## Where things live

| What | Where |
|---|---|
| The command | `bin/keep-awake`, library `bin/lib/keep_awake.rb` |
| The 1Password watch | `bin/lib/keep_awake_op_probe.rb` |
| The menu-bar indicator | `bin/lib/keep_awake_indicator.swift`, compiled with `swiftc` on first use |
| State, lock, log | `/Users/alex/projects/.agents/keep-awake/` (`state.json`, `state.lock`, `history.log`, `op-probe.log`, `op-probe.noted`, `supervisor.log`) |
| Tests | `test/lib/keep_awake_test.rb`, `test/lib/keep_awake_op_probe_test.rb`, `test/commands/keep_awake_command_test.rb` |
| Test seams | `MCR_KEEP_AWAKE_OP`, `MCR_KEEP_AWAKE_IOREG`, `MCR_KEEP_AWAKE_PROBE_DEADLINE`, `MCR_KEEP_AWAKE_PROBE_EVERY` (`0` turns the probe off), `MCR_KEEP_AWAKE_PROBE_HUNG_EVERY`, `MCR_KEEP_AWAKE_PROBE_NOTE_AFTER` |

`history.log` and `op-probe.log` use the same UTC timestamps as
`/Users/alex/projects/.agents/op-reads.log`, so hold windows and probe rows line
up against 1Password stalls. The hypothesis being tested: `op` wedges when the
user is idle, even while caffeinate holds the Mac and its display awake. The
`idle_seconds` column is the evidence for or against it.
