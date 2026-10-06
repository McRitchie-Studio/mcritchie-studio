# Ports And Processes

Local app ports are assigned in hundreds so each app has room for worktree and parallel-test stacks.

Each app's primary port is its `port` in `config/apps.yml` (the app catalog);
its block is that port through port + 99. `config/satellites.yml` reserves the
same blocks for desks, and `test/lib/app_registry_test.rb` fails if the two
disagree.

| App | Primary port | Reserved range | Catalog status |
|-----|--------------|----------------|----------------|
| McRitchie Studio | 3000 | 3000-3099 | Active |
| Turf Monster | 3100 | 3100-3199 | Showcase |
| Tax Studio | 3200 | 3200-3299 | Archived |
| Rolio | 3300 | 3300-3399 | Archived |
| Chain Ops | 3400 | 3400-3499 | Archived |
| McRitchie Industries | 3500 | 3500-3599 (3510 held) | Active |
| Cyvasse | 3600 | 3600-3699 | Showcase |
| Dads App | 3700 | 3700-3799 | Showcase |
| Prisoners Dilemma | 3800 | 3800-3899 | Showcase |
| Weekly Lock | 3900 | 3900-3999 | Showcase |
| Rantly | 4000 | 4000-4099 | Showcase |
| Portfolio | 4100 | 4100-4199 | Showcase |
| 10&5 Hospitality | 4200 | 4200-4299 | Showcase |
| Search Position | 4300 | 4300-4399 | Showcase |
| Moms App | 4400 | 4400-4499 | Active |

Archived apps keep their blocks; do not reuse `3200-4499`. Which apps are
managed satellites, release-managed standalones or neither is in
[`app-registry.md`](app-registry.md). The unmanaged MSAA client workspace
informally parks a dev app on `3510` inside McRitchie Industries' block; the
worktree launcher excludes it (`reserved_ports` in `bin/agent-worktree`), and no
McRitchie Industries side stack should sit on it until MSAA moves.

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

For parallel work, primary ports (`3000`, `3100`, `3200`, `3300`, `3400`,
`3500`, `3600`) are stable review and callback lanes. Worktree ports (`3001+`, `3101+`,
`3201+`, `3301+`, `3401+`, `3501+`, `3601+`) are isolated desks
for agents to build, test, and hand back URLs without moving another agent's
ground.

## Known Callback Commands

For Turf Monster local Stripe verification, forward to the primary port unless the provider has been reconfigured:

```bash
stripe listen --forward-to localhost:3100/webhooks/stripe
```

If purchases stall locally, confirm the listener before assuming the Rails app is broken.
