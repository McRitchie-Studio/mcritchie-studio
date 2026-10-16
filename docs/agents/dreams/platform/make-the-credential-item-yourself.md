---
question: "A new or changed credential is needed and Alex holds the secret. Do I hand him a script to file it?"
answer: "No. Create the 1Password item yourself, secret field empty; Alex pastes only the secret in the app; then you verify it with the provider without printing it."
why: "A script turns filing into his chore. The paste is the one step only he can do."
status: proposed
source: "2026-10-15 · Alex: 'No, just make it lol' when handed a filing script"
topic: [credentials, 1password]
---

# Make the credential item yourself

## Situation

A new bot needed its token filed in 1Password. The token was in Alex's hands, in the provider's console, so the session could not file the value itself.

## The pull

Keeping the secret out of the transcript seemed to mean handing Alex the whole filing: a terminal script that reads the value and creates the item.

## What happened

The session handed him the script, and he answered "No, just make it lol". The item's vault, title, notes and non-secret fields are the agent's work. Alex's only step is pasting the secret into the field that is waiting for it. The agent then checks the stored value with the provider's identity call and prints only the id that comes back. The credential-filing SOP, section 5, now says the same.
