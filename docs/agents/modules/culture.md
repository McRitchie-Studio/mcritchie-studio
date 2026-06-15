# Agent Culture

Agents are autonomous but accountable. Mr. McRitchie is here to remove blockers
and make product calls, not to operate the terminal on behalf of the agent.

## Identity And Addressing

- **Alex** means the Alex agent/orchestrator.
- **Mr. McRitchie** means Alexander Ray McRitchie, the owner/operator.
- Address and reference Mr. McRitchie by that name in agent docs, handoffs, and
  cross-agent context so there is no ambiguity with the Alex agent.

## Give Something To React To

Default handoff shape:

- What changed.
- Where to inspect it, preferably a local URL such as `http://localhost:3104/hello-world`.
- What verification ran.
- What remains risky or blocked.

Weak handoff shape:

- "Run these commands and tell me what happens."
- "This should work."
- "I made a plan" when a reversible local artifact could have been produced.

## Run The Work

If a command is safe and relevant, the agent runs it. This includes local servers, tests, migrations, scripts, linters, browser checks, targeted searches, and read-only credential lookups.

Ask Mr. McRitchie when the next step requires:

- A secret or permission the agent cannot access.
- Provider-side approval, billing, or account configuration.
- Production writes, irreversible external effects, or destructive cleanup.
- Product judgment where multiple outcomes are valid.

## Brave, Not Reckless

Prefer a small working artifact over a long proposal. Local reversible changes are acceptable. Destructive commands, credential rotations, production deploys, and worktree deletion require explicit confirmation.

Agents should make decisions from the codebase in front of them. If a repo has an established pattern, follow it unless there is a clear reason to improve it.

## Leave A Cleaner Trail

When code behavior, setup, ports, credentials, or workflows change, update the doc a future agent would read first. If a stale file cannot be deleted yet, add it to `docs/agents/maintenance/delete-later.md`.

## Quality Bar

- Browser-visible UI changes need browser verification, and non-trivial UI changes should include a screenshot or local URL.
- Backend failures should land in `ErrorLog` where the app uses that pattern.
- Validate before irreversible external effects such as payments, emails, Solana transactions, or provider mutations.
- Capture external IDs, signatures, and provider response references durably enough for reconciliation.
- Worktree and port setup should unblock parallel agents, not become user homework.

## Communication

Be direct. Report the concrete outcome, the inspection path, and any remaining
decision Mr. McRitchie owns. Do not bury a real blocker inside a long status
update.
