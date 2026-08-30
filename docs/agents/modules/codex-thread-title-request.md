# Codex Thread Title Request

Use this copy when asking Codex/OpenAI to make live thread-title updates a
supported hook capability. The goal is to keep McRitchie machines on stock Codex:
plugins, managed hooks, and `bin/agent-runtime install` should be enough.

## Feature Request

Please add official Codex hook support for setting the current thread title from
hook output, for example:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "threadName": "Haunter · rolio · rolio-demo-polish-rehearsal"
  }
}
```

The requested behavior:

- `SessionStart` may set the initial thread title before the first model turn.
- `PostToolUse` may refresh the title after task/context changes.
- Codex persists the name to the local thread store.
- The live TUI footer repaints without requiring `/rename`.
- The update can be silent, so no hook context or rename transcript noise appears.
- Stock Codex handles this through hooks, plugins, or managed config without a local patched binary.

This lets teams show durable, machine-portable session identity in the standard
`thread-title` status-line item. In McRitchie Studio, that identity is:

```text
Pokemon · app · feature
```

## Email

Subject: Feature request: allow Codex hooks to update thread-title

Hi Codex team,

I would like Codex hooks to support setting the current thread title from hook
output. The use case is a portable session identity shown in the built-in
`thread-title` status-line item, such as `Haunter · rolio ·
rolio-demo-polish-rehearsal`.

Ideally, `SessionStart` could set the initial title and `PostToolUse` could
refresh it after task context changes:

```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","threadName":"Haunter · rolio · rolio-demo-polish-rehearsal"}}
```

The important details are persistence plus live repaint: write the title to the
thread store and emit the same in-memory update the TUI uses for `/rename`,
without adding visible hook context or rename history to the transcript.

That would let teams distribute this with plugins or managed hooks on stock
Codex, instead of maintaining local patched CLI binaries.

Thanks.

## X

Feature request for Codex: let hooks set the live `thread-title`.

Use case: portable session identity in the footer, e.g.
`Haunter · rolio · task-slug`.

`SessionStart` sets it, `PostToolUse` refreshes it, Codex persists it and
silently repaints the TUI. No local patched CLI.

## LinkedIn

I would love to see Codex add official hook support for live thread-title
updates.

The practical use case is team-standard session identity in the terminal footer:
`Pokemon · app · feature`. A `SessionStart` hook could assign the initial
identity, and a `PostToolUse` hook could refresh it when the active task changes.

The key is that Codex would persist the value and repaint the live TUI footer
silently, using the same internal path as `/rename`, without adding hook context
or rename noise to the transcript.

That would let teams ship this behavior through plugins or managed hooks on
stock Codex instead of maintaining local patched CLI builds.

## GitHub Issue

Title: Allow hooks to update live thread-title

### Problem

Codex has a built-in `thread-title` status-line item, but stock Codex 0.144.3
does not provide a hook output field that updates the live TUI footer. Updating
the persisted local title is visible on resume, but not in the already-running
session because the footer reads the in-memory thread name.

### Proposed API

Allow hooks to return:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "threadName": "Haunter · rolio · rolio-demo-polish-rehearsal"
  }
}
```

Support the same field for `PostToolUse`.

### Expected Behavior

- Normalize and persist the supplied thread name.
- Emit a silent internal thread-name update so the TUI footer repaints.
- Avoid transcript-visible hook context and `/rename` history.
- Work from ordinary hooks, plugin-bundled hooks, and managed hooks.

### Why

Teams can standardize session identity across machines using stock Codex. For
McRitchie Studio, the marker is `Pokemon · app · feature`, installed through a
fresh-machine runtime bootstrap.

## Slack Or Discord

Small Codex feature request: hooks should be able to update the live
`thread-title`. We want a portable footer identity like `Haunter · rolio ·
task-slug` from `SessionStart`, then refresh it after task creation from
`PostToolUse`. If Codex persists it and silently repaints the TUI, teams can ship
this with plugins/managed hooks instead of patched local CLI builds.
