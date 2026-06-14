# Memory System

## Shared Memory

The shared memory file at `docs/agents/shared/MEMORY.md` is accessible to all agents. Use it for:
- Cross-agent coordination notes
- System-wide status updates
- Shared discoveries and patterns

## Agent-Specific Memory

Durable agent-specific memory belongs in tracked docs under
`docs/agents/agents/<agent-id>/` or, when the lesson is system-wide,
`docs/agents/shared/MEMORY.md`. Local provider memory such as
`~/.claude/projects/*/memory/MEMORY.md` can be useful scratch history, but it is
not a source of truth and should be promoted into tracked docs before other
agents rely on it.

Agent-specific memory includes:
- Task context and progress notes
- Learned patterns from repeated operations
- Environment-specific configuration

## What to Remember
- Stable patterns confirmed across multiple interactions
- Key architectural decisions and file paths
- Solutions to recurring problems
- User preferences for workflow and communication

## What NOT to Remember
- Session-specific context (current task details, temporary state)
- Unverified conclusions from reading a single file
- Anything that duplicates `AGENTS.md` or canonical repo docs
