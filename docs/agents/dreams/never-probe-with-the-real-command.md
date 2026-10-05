---
question: "I need to know whether a lease has expired, or what flags a script takes. Can I just run it and see?"
answer: "Not a script that mutates. Read its source or use a read-only command. A refusal you were counting on may come after the first write."
why: "A probe run of the ship command committed eight files under the message 'probe', and a guessed `--help` ran a real sweep across nine repos."
status: approved
source: "2026-08-26 \u00b7 session 9e42c2b3"
---

# Never probe with the real command

## Situation

Two separate probes, both expected to do nothing.

## The pull

Running it is the fastest way to find out.

## What happened

Both were recovered. Sessions now read the script or its doc first, and every script in `bin/` is classified for how it treats an unknown argument.
