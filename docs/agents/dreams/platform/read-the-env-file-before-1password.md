---
question: "I need a credential. Do I just run `op read`?"
answer: "No. Env file, then the secret cache, then op only through the metered wrapper; write down the item name, never the value. Run the credential-access SOP."
why: "All agents share 1,000 1Password reads a day. On 2026-10-31 an unmetered loop spent them and every agent stalled for five hours."
status: proposed
source: "2026-10-31 · one-way-into-1password"
topic: [credentials, 1password]
---

# Read the env file before 1Password

## Situation

A session needs a key: the board secret, a GitHub token, an app's API key. `op read`
is one command away and always works.

## The pull

Run `op read` directly, or paste the value into a memory note so the next session
skips the lookup. Both feel like the shortest path.

## What happened

On 2026-10-30 and 2026-10-31 a watcher re-read 1Password once a minute while it was
down, and a list of callers read it without the meter, so nobody could say what had
spent the account's daily quota until it was gone. Every agent stalled for about
five hours. Alex McRitchie asked for one standard every agent dreams about: read
the env file first, then the cache, then `op` through the one metered wrapper; and
keep names, never values, in memory, so a rotation flips one place.
