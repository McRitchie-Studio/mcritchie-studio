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
bin/codex-update promote --binary /path/to/built/codex --version <version> --yes
```

The tracked patch is version-neutral by name and currently verified against
OpenAI's `rust-v0.144.3` source tag. Rebase and reverify it whenever the stock
runtime changes the touched hook, protocol, rollout, or TUI surfaces.

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

## Detecting An Unmanaged Install

`bin/agent-runtime doctor` calls `bin/codex-update inspect` and fails on its
exit 2:

```
fail: Codex runtime lacks live thread-title repaint support; an unmanaged Codex
install replaced the patched runtime — restore it with bin/agent-runtime codex-update run
```

Nothing cheaper can catch this. Stock and patched runtimes self-report the SAME
`codex-cli` version, so `codex --version` cannot tell them apart, and the
`~/.codex/mcritchie-live-thread-title.enabled` sentinel is a zero-byte opt-in
touch-file that survives any reinstall — it records that the operator WANTS live
repaint, never that the runtime still delivers it. Only reading the binary's
SessionStart wire-struct arity distinguishes the two, which is what `inspect`
does.

This is the guard for the path `run` cannot cover: `run` saves a last-good
runtime and relinks it when an update loses hook support, but a raw
`curl … install.sh` bypasses `run` entirely. Doctor is where that shows up.

## Rules

- Do not choose Codex's startup update prompt for McRitchie workstations.
- Keep `check_for_update_on_startup = false` in `~/.codex/config.toml`.
- Treat `bin/codex-update plan` as the review step before any update.
- Keep the stock release on disk when rollback happens; the patched runtime owns
  `current` until a hook-capable replacement is promoted.
