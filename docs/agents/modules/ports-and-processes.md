# Ports And Processes

Local app ports are assigned in hundreds so each app has room for worktree and parallel-test stacks.

| App | Primary port | Reserved range |
|-----|--------------|----------------|
| McRitchie Studio | 3000 | 3000-3099 |
| Turf Monster | 3100 | 3100-3199 |
| Tax Studio | 3200 | 3200-3299 |

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

## Known Callback Commands

For Turf Monster local Stripe verification, forward to the primary port unless the provider has been reconfigured:

```bash
stripe listen --forward-to localhost:3100/webhooks/stripe
```

If purchases stall locally, confirm the listener before assuming the Rails app is broken.
