---
question: "A tool I am about to run wants the browser's cookies or a keychain item. Do I run it?"
answer: "Not unannounced. Stop, tell Alex which command needs which secret and why, and prefer a purpose-built path (a named 1Password reference, an exported cookie file) over the login keychain."
why: "The OS dialog lands on Alex's screen naming only `security`; he cannot tell who is asking, and one Always Allow hands every logged-in session to any later process."
status: proposed
source: "2026-10-04 \u00b7 a peer session's cookie read"
---

# Credential dialog is not yours to raise

## Situation

A session ran a tool that read Chrome's cookie store. macOS answered with a password dialog for "Chrome Safe Storage", on top of whatever Alex was doing, with no word from the session that had caused it.

## The pull

The tool has a flag for it, the flag works on every other machine, and the dialog is 'just a prompt'.

## What happened

This is the founding counter-example: the session did not announce it. The good answer is to stop before the command, say what it will ask for, and let Alex choose the route.
