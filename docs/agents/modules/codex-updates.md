# Codex Updates

McRitchie machines keep Codex updates deliberate because the Pokemon status-line
marker depends on live `thread-title` hook behavior. A stock Codex update may
replace a locally patched runtime and leave history/resume titles working while
the live footer stops repainting.

Use `bin/codex-update` instead of the startup update prompt.

## Normal Review

From McRitchie Studio:

```bash
bin/codex-update plan
```

The plan command checks:

- the active Codex version;
- the latest OpenAI Codex release metadata;
- the active binary's `SessionStart` hook-output schema;
- whether the runtime can consume `hookSpecificOutput.threadName`;
- the local McRitchie patch path to use if stock Codex lacks support.

It does not mutate the machine.

## Safe Stock Update

When you want to try the latest stock release:

```bash
bin/codex-update run --yes
```

The command records the current known-good runtime, runs the official Codex
installer, disables startup update prompts, inspects the installed binary, and
keeps the new runtime only when the live thread-title hook is supported. If the
new stock binary lacks support, the command restores the previous `current`
runtime symlink and leaves the live repaint sentinel enabled.

## Patching A New Release

If stock Codex still lacks hook support, patch and build a source checkout:

```bash
bin/codex-update apply-patch --source /path/to/openai-codex
# build Codex from that checkout
bin/codex-update promote --binary /path/to/built/codex --version 0.142.4 --yes
```

`promote` refuses binaries that do not contain live `threadName` hook support.
On success it creates a versioned runtime under
`~/.codex/packages/standalone/releases/`, switches
`~/.codex/packages/standalone/current`, disables startup update prompts, enables
`~/.codex/mcritchie-live-thread-title.enabled`, and records a rollback target.

## Rollback

To restore the last known-good runtime recorded by `run` or `promote`:

```bash
bin/codex-update restore --yes
```

Then verify:

```bash
bin/agent-runtime doctor
bin/agent-marker current --format title
```

## Rules

- Do not choose Codex's startup update prompt for McRitchie workstations.
- Keep `check_for_update_on_startup = false` in `~/.codex/config.toml`.
- Treat `bin/codex-update plan` as the review step before any update.
- Keep the stock release on disk when rollback happens; the patched runtime owns
  `current` until a hook-capable replacement is promoted.
