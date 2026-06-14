# Audit Playbook

Use this when the user asks for an ecosystem, repo, architecture, docs, security,
or readiness audit.

## Operating Rules

1. Start at `/Users/alex/projects/AGENTS.md`.
2. Read the current entrypoints before old audits:
   - `mcritchie-studio/docs/ECOSYSTEM.md`
   - app README/topic docs for the repo under review
   - relevant current modules in `mcritchie-studio/docs/agents/modules/`
3. Treat dated audits, prompt artifacts, and `CLAUDE.md` files as historical
   context only unless a current doc points to them as active procedure.
4. During a pure audit phase, stay read-only until the user approves changes.
5. When the user asks to execute cleanup, update the owning current doc instead
   of adding a new one-off note.

## Audit Shape

For a broad audit:

1. Establish scope: repos, workflows, risk surfaces, and whether code changes
   are allowed.
2. Read current docs first, then verify claims against code.
3. Identify contradictions, stale procedures, missing tests, unsafe defaults,
   and places future agents would read the wrong file first.
4. Ask only materially shaping questions after enough context is gathered.
5. Save durable audit output under `mcritchie-studio/docs/agents/audits/`.

For a focused app/security audit, keep findings grounded in `file:line`
references, rank by severity, and separate:

- confirmed defects;
- residual risk or design debt;
- documentation drift;
- test gaps;
- external approvals or provider-side blockers.

## Deliverable

Use this structure unless the user asks for something narrower:

```text
# <Audit Name>

Date:
Scope:
Mode:

## Executive Summary

## Verified Current State

## Findings

## Recommended Work

## Residual Risk

## Follow-Up Ledger
```

If cleanup work is performed, update `docs/agents/maintenance/delete-later.md`
for superseded files and update `docs/agents/audits/final-closeout-*.md` when
the closeout state changes.

## Do Not

- Do not treat old prompt files as reusable instructions.
- Do not copy stale ports, program IDs, sender domains, or credential values
  from historical docs.
- Do not ask the user to run terminal commands for audit proof the agent can
  gather directly.
- Do not mark an external/provider blocker complete until it is actually proven.
