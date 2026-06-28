# Ports And Processes

Local app ports are assigned in hundreds so each app has room for worktree and parallel-test stacks.

| App | Primary port | Reserved range |
|-----|--------------|----------------|
| McRitchie Studio | 3000 | 3000-3099 |
| Turf Monster | 3100 | 3100-3199 |
| Tax Studio | 3200 | 3200-3299 |
| Rolio | 3300 | 3300-3399 reserved |
| Chain Ops | 3400 | 3400-3499 |

The durable app registry decision surface is
`mcritchie-studio/docs/agents/modules/app-registry.md`. Rolio's range is
reserved, and its hosted QA/prod deploy targets are managed by the release
registries. It is not managed by rebuild/nav automation. Chain Ops is planned for
localnet/QA/node operations.

## Primary Ports

Primary ports are for flows that depend on external callbacks, stable redirect URIs, email links, or service configuration.

Examples:

- Stripe webhook forwarding
- Google OAuth redirects
- MoonPay/CDP callbacks
- Magic links and mailer URLs
- SSO links between apps

## Parallel Ports

Worktree and temporary stacks use the app's next port in its range.
Ports are allocated by the worktree launcher, not guessed by the agent.

Examples:

- Turf Monster primary: `3100`
- Turf Monster first worktree stack: `3101`
- Turf Monster second worktree stack: `3102`

Use the central launcher to allocate ports and print the review URL:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree plan turf-monster task-slug
bin/agent-worktree new turf-monster task-slug
bin/agent-worktree up turf-monster task-slug
```

Keep callback-heavy flows on the primary stack unless the external provider has been configured for the alternate port.

For parallel work, primary ports (`3000`, `3100`, `3200`, `3300`, `3400`) are
stable review and callback lanes. Worktree ports (`3001+`, `3101+`, `3201+`,
`3301+`, `3401+`) are isolated desks
for agents to build, test, and hand back URLs without moving another agent's
ground.

## Known Callback Commands

For Turf Monster local Stripe verification, forward to the primary port unless the provider has been reconfigured:

```bash
stripe listen --forward-to localhost:3100/webhooks/stripe
```

If purchases stall locally, confirm the listener before assuming the Rails app is broken.
