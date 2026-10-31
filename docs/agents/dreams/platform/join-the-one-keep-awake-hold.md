---
question: "Work will run past when Alex McRitchie is at the Mac (an overnight release, a long build). How do I keep the machine awake?"
answer: "Run /Users/alex/projects/.agents/bin/keep-awake status first and join a live hold; else keep-awake start --by <you> --reason \"<why>\". Renew every 30 minutes, stop --by <you> when done, and never run a caffeinate of your own. SOP: docs/agents/agents/steffon/sops/keep-awake.md."
why: "An idle Mac slept and ate overnight runs; one shared, leased hold is what Alex McRitchie sees in his menu bar and lapses by itself if you die."
status: approved
source: "2026-10-30 · Alex McRitchie asked for it in chat"
topic: operations
---

# Join the one keep-awake hold

## Situation

An unattended overnight run lost 7 of 12 steps when the Mac idle-slept on
battery, and each agent had kept the Mac awake its own way, if at all.

## The pull

Wrap the command in a private `caffeinate` and move on.

## What happened

Alex McRitchie asked for one shared mode any agent can start and others can see:
`keep-awake` holds a single `caffeinate -dims` under 30-minute leases, shows the
hold in his menu bar, and lets the Mac sleep once every holder releases or lapses.
The lid stays open or the Mac stays on power; caffeinate cannot hold a closed lid
on battery.
