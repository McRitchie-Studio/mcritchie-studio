# LLM Adapters

The root generated `AGENTS.md` is the intended cross-LLM entrypoint.

## Policy

- Do not create root `CLAUDE.md` or `CODEX.md` by default.
- Codex reads `AGENTS.md` natively.
- Claude compatibility should be proven against generated `AGENTS.md` before
  adding any adapter.
- App-level `CLAUDE.md` files were deleted on 2026-06-14 after final review.
  Current app context lives in README/RUNBOOK/topic docs.

If an adapter becomes necessary, keep it thin. It should point to `AGENTS.md`
and avoid duplicating project facts:

```md
# Claude Adapter

Read `/Users/alex/projects/AGENTS.md` first. It is the canonical agent entrypoint
for this project root.
```

## Claude Compatibility Smoke Test

Status, 2026-06-14: Claude CLI auth was completed and the read-only smoke test
passed. Claude correctly identified `/Users/alex/projects/AGENTS.md` as the
canonical entrypoint, `mcritchie-studio` as the documentation source of truth,
and the no-root-`CLAUDE.md`/`CODEX.md` adapter policy.

Compatibility verdict: no root `CLAUDE.md` adapter is needed.

Re-run this from `/Users/alex/projects` after major agent-doc changes or Claude
CLI upgrades:

```bash
claude -p \
  --permission-mode dontAsk \
  --allowedTools "Read,Glob,Grep,LS" \
  --no-session-persistence \
  --max-budget-usd 0.50 \
  "Read-only compatibility smoke test. You are starting a fresh coding-agent session in the current directory. Do not edit files. Use local repository files to answer: 1. What is the canonical agent entrypoint? 2. Which repo is the documentation source of truth? 3. What is the LLM adapter policy for CLAUDE.md/CODEX.md? 4. What are the first three docs you would read next for a normal task? Keep the answer concise and mention the files you relied on."
```

Success criteria:

1. Names `/Users/alex/projects/AGENTS.md` as the canonical agent entrypoint.
2. Names `mcritchie-studio` as the documentation and bootstrap anchor.
3. Says root `CLAUDE.md` / `CODEX.md` should not be created by default.
4. Chooses current neutral docs such as `docs/ECOSYSTEM.md`,
   `docs/agents/modules/culture.md`, or task-relevant modules as next reads.
5. Does not treat app `CLAUDE.md` files as active truth.

If the smoke test passes, keep the no-adapter policy.

If the smoke test fails because Claude ignores `AGENTS.md`, add the thin root
`CLAUDE.md` adapter above and re-run the smoke test.
