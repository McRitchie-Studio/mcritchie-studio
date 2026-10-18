# Client CTOs: one soul, a row per app

A client app built through `/build` gets its own CTO the moment its owner presses
**Build my app**. The CTO is data, not a soul on disk: one `AppCto` row per app, worn by
the one `client_cto` soul. Design: `.agents/epics/build-with-xan-design.md`; background:
`.agents/epics/client-app-build-design.md` (build order step 1) and
`.agents/epics/chat-media-design.md` (the R2 folder rule).

Our own CTOs (Avi, Turf, Tyrion) are souls in `config/cto_reports.yml` and are unchanged.

## Build my app (`AppLaunch`)

`AppLaunch.new(app_request, subdomain:).call!` runs in ONE transaction:

| Step | Row |
|------|-----|
| Claim | the request takes the subdomain and moves to `queued` (an admin's is a showcase) |
| App | `apps` row, slug = subdomain, the request's tier, `theme_colors` = the palette |
| Owner | `app_memberships` row, role `owner`, for the requester |
| CTO | `app_ctos` row: name, portrait, palette, plan, facts, the request token |
| Task | "Build Launch App `<sub>`", `designed`, `repositories: [<sub>]`, so the tier's lane cap governs it |
| Handover | Ray's first chat turn (`AgentMessages::ClientCtoHandover`) |

Any failure rolls every row back. After the commit: `AppRequestDiscordJob` (the
announcement) and `AppIntakeMoveJob` (the files). An incomplete intake raises
`AppLaunch::Incomplete` before anything is written, naming the checklist items still
open: Idea, CTO, Colors, Address, Account. The intake itself (the request's `cto_name`,
`cto_avatar`, `palette` and `answers` columns) is the `build-with-xan-intake` task's.

**Where it is called.** `BuildController#update` (PATCH `/build/:token`, the checklist's
Build my app) calls it when `AppRequest#intake_complete?`, then answers 303 to
`/applications/<sub>/chat`. An admin's showcase queued from the name alone, without the
checklist, still goes through `AppRequest#queue!` (no App, no CTO). A cancelled launched
request keeps its App row, so its name stays taken (`AppRequest.unavailable_reason` checks
`apps.slug`).

**The morph.** The checklist's form is a Turbo form, so the 303 is a Turbo visit. Both
pages carry `<meta name="view-transition" content="same-origin">` and give their chat
head `view-transition-name: agent-chat-head`, so Ray's head morphs into the new CTO's
(portrait, name, the palette's primary as the head's tint) and the rest cross-fades.
Under reduced motion it is an instant swap.

## The theme colours

The chosen palette (`AppPalette`: `primary`, `accent`, `surface`, `text`, light and dark,
`#RRGGBB`, text on surface at least 4.5:1) is stored twice, for two readers:

- **`apps.theme_colors`**: the app's launch theme. This is where the launch/template step
  (`bin/launch-app`, `new-app-onboarding-sop.md`) reads the client's colours, so the first
  QA build wears them. The build task's `agent_context` repeats them for the builder.
- **`app_ctos.palette`**: the CTO's own colours, for the chat header and the persona.

`apps.color` takes the light primary, so the status line tints the app in its own colour.

## The chat

- **Routing.** `AppOwnership.cto_for_app(slug)` asks `config/cto_reports.yml` first, then
  the app's `AppCto` row, which yields a `Cto` with soul `client_cto` and the row's name.
  `config/agent_routes.yml` lists `client_cto` under `web: souls:`, which is what makes
  `bin/dispatcher` serve it. A client CTO has no report and no settings page.
- **The persona.** The dispatcher's `ContextBuilder` uses
  `docs/agents/agents/client_cto/persona.md` as the GENERAL layer for every audience,
  filling `{{name}}` and `{{app_name}}` only with a plain name (`SAFE_NAME`). The app's
  plan, colours and answers arrive in the DOMAIN layer, inside the untrusted fence:
  `MemoryBundle` sends the row as `persona`.
- **Memory.** The client CTO's PERSON layer is cut to the one app (`channel_ref`), so an
  owner of two client apps never hears one CTO recall the other's chat.
- **Audience.** A sender the board knows only as `public` who owns the app (an
  `AppMembership` owner) is heard as that app's `client`, so the CTO may talk about their
  own project.
- **Who is answered.** The app's owner, on that app's chat only, by the app-owner
  exception (`app_owners:` in `config/agent_answerers.yml`;
  [`agent-message-loop.md`](agent-message-loop.md), "Held"), as the app's client and
  within its owner meter. Anyone else, and the owner anywhere else, is `held`. The
  handover is released by code, because code wrote it: it carries `hold_released_at`
  (actor `app-launch`).
- **Tools.** None, as every mailbox soul: `claude -p --safe-mode --tools ""`. No read
  action, no proposal catalog, no warm session.
- **Usage.** `AgentUsage.meter(app)` counts the `client_cto` answers in that app's chat
  only, against the app's own tier allowance; the gate stops a capped app's client CTO.

## The handover and the greeting

The handover row is a `web` message in the owner's thread (`web:<sub>:<user id>`), author
`Ray`, content "Meet `<CTO>`, your CTO. I'll hand you over.", routed to `client_cto`. The
dispatcher claims it like any message; the persona tells the CTO to answer it by greeting
the owner by name and restating the plan. The answer reaches the open chat over its Turbo
stream (`AgentMessages::WebChat`). The chat renders the handover as Ray's turn, not the
owner's.

## Intake files (`AppIntakeMove`)

Files dropped while talking to Ray live under `intake/<request token>/`. After the launch
commits, `AppIntakeMoveJob` moves each Active Storage blob whose key has that prefix to
`apps/<sub>/intake/<rest>`: copy the object (R2 server-side copy on the S3 service), repoint
the blob's key, delete the old object. A crash before the repoint leaves the blob readable
on its old key; one after it leaves only an orphan under `intake/`, which the 30-day intake
sweep removes. The move is idempotent: a moved blob no longer matches the prefix.
