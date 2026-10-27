# Client CTOs: one soul, a row per app

A client app built through `/build` gets its own CTO the moment its owner presses
**Build my app**. The CTO is data, not a soul on disk: one `AppCto` row per app, worn by
the one `client_cto` soul. Design: `.agents/epics/build-with-xan-design.md`; background:
`.agents/epics/client-app-build-design.md` (build order step 1) and
`.agents/epics/chat-media-design.md` (the R2 folder rule).

Our own CTOs (Avi, Turf, Tyrion) are souls in `config/cto_reports.yml` and are unchanged.

The app's first version is a static bundle on the shared client-app host, at
`<sub>.mcritchie.app`; until one is published, that address shows a "being built" page in
the CTO's colours: [`client-app-host.md`](client-app-host.md).

## Build my app (`AppLaunch`)

`AppLaunch.new(app_request, subdomain:).call!` runs in ONE transaction:

| Step | Row |
|------|-----|
| Claim | the request takes the subdomain and moves to `queued` (an admin's is a showcase) |
| App | `apps` row, slug = subdomain, the request's tier, `theme_colors` = the palette |
| Owner | `app_memberships` row, role `owner`, for the requester |
| CTO | `app_ctos` row: name, portrait, palette, plan, facts, the request token |
| Task | "Build Launch App `<sub>`", `designed`, `repositories: [<sub>]`, so the tier's lane cap governs it. `bin/client-build-launcher` claims it and builds the first version automatically ([`client-build-launcher.md`](client-build-launcher.md)) |
| Handover | Alex's first chat turn (`AgentMessages::ClientCtoHandover`) |

The CTO's portrait is an avatar id: `animal:<id>` from the 100-animal bank
(`BuildIntake::Animals`, glyphs in `app/assets/images/cto_animals/`, Microsoft Fluent
Emoji, MIT) drawn at render time in the app's palette (`CtoAvatarHelper#cto_avatar_tag`),
or one of the twelve older portrait keys (`BuildIntake::Portraits`), which still render.
The owner re-picks it in the chat: the head's portrait, or the CTO's code answer to an
avatar ask (`AgentMessages::AvatarAsk`), opens the picker, and `CtoChatsController#avatar`
saves it.

Any failure rolls every row back. After the commit: `AppRequestDiscordJob` (the
announcement) and `AppIntakeMoveJob` (the files). An incomplete intake raises
`AppLaunch::Incomplete` before anything is written, naming the checklist items still
open: Idea, CTO, Theme, Domain, Account. The intake itself (the request's `cto_name`,
`cto_avatar`, `palette` and `answers` columns) is the `build-with-xan-intake` task's.

**Where it is called.** `BuildController#update` (PATCH `/build/:token`, the Build My App
control on Alex's summary card) calls it when `AppRequest#intake_complete?`, then answers with a 303 to
`/applications/<sub>/chat`, whose first visit plays the launch panel (below, "The
handover and the greeting"). Signed out, the press opens the sign-in modal first and the
sign-in's landing (`GET /build/:token/launch`) calls it the same way. An admin's showcase queued from the name alone, without the
checklist, still goes through `AppRequest#queue!` (no App, no CTO). A cancelled launched
request keeps its App row, so its name stays taken (`AppRequest.unavailable_reason` checks
`apps.slug`). A refusal (`AppLaunch::Incomplete`, a `RecordInvalid` such as the tier's
apps-per-account limit or a name taken since the tap; the claim re-checks the name)
answers on the summary card as a Turbo Stream with the reason and a next step, never a
422 page. The limit is data: `apps_per_account` per tier in
`config/workspace_packages.yml`, blank for unlimited, which every tier is since
2026-10-18 (it was one Vibe app).

**The morph.** The Build control posts through Turbo, so the 303 is a Turbo visit. Both
pages are the agent shell (`app/views/agent_chats/_shell.html.erb`) and carry
`<meta name="view-transition" content="same-origin">`; the shell names its portrait
(`agent-portrait`), caption, status card (`agent-status`) and chat box
(`agent-composer`) on every page, so Alex's portrait morphs into the new CTO's, the draft's
Agent · Theme · Domain card into the app's Building · Releasing · Deploying card (in the
palette's primary), and the rest cross-fades. Under reduced motion it is an instant swap.

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
- **The owner's Google.** On the app owner's own CTO thread, `MemoryBundle` adds
  `google_context`: a 5-minute-cached, read-only snapshot of the OWNER's own connected
  Google (calendar, newest mail headers and snippets, newest Drive files), printed in the
  GOOGLE layer inside the untrusted fence. A visitor, another app's owner, and any other
  audience get none (`docs/agents/system/agent-message-loop.md`, "The Google layer").
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
- **Confirming.** With no catalog the client CTO proposes nothing, so there is nothing
  for its owner to confirm yet. When one lands, the owner's `go`, `no` or `change: …`
  on their own app's chat is decided by `ProposalConfirm#owner_verdict`: a `change`
  only, under the owner meter ([`agent-message-loop.md`](agent-message-loop.md),
  "Confirm by reply").
- **Usage.** `AgentUsage.meter(app)` counts the `client_cto` answers in that app's chat
  only, against the app's own tier allowance; the gate stops a capped app's client CTO.

## The handover and the greeting

The handover row is a `web` message in the owner's thread (`web:<sub>:<user id>`), author
`Alex`, content "Meet `<CTO>`, your CTO. I'll hand you over.", routed to `client_cto`. It is
stored already answered with the CTO's opening message, which code writes from the launch
(`ClientCtoHandover.greeting`: in the first person, "Hi `<first name>`, I'm `<CTO>`, the agent
who'll be managing `<app>`", that it is in line to be built, what the status card shows, the
app's address, and what the owner can do meanwhile), so the chat opens on both turns and no
model runs for it. It never says "building now": at launch the build task is `designed` and
nobody holds it (task `app-card-stage-labels`). A greeting already stored keeps its words.

**A nameless owner is asked in the chat** (task `cto-chat-quality-pass`): with no first name
and no name, the greeting ends "Before we dive in, what should I call you? Just your first name
is fine, or say skip." and carries `run_meta.asks_first_name`. The owner's next message, if it
reads as a name or a skip ("skip", "not now"), is answered in code with no model
(`AgentMessages::FirstNameAsk`). **When in doubt it goes to the model**: a name is ONE word
("Ada"), TWO words each typed with a capital ("Mary Jane"), up to three in any case after a
strong cue ("call me", "my name is"), or up to three each typed with a capital after a weak one
("I'm Ada", never "I'm so excited"), and any word in `STOP_WORDS` (acknowledgements, common
request verbs, function words, app nouns: "Add dark mode", "Sounds good", "Ship it") rejects it.
A name is written as the engine's onboarding step writes it (`Studio::NameParts`, the same caps,
`update_columns`, `name` backfilled); the reply says how to fix it ("Not right? Say "call me" and
your name."), and the very next message, only with a strong cue ("call me Al"), corrects it. A skip sets the engine's
session skip. Anything else goes to the model and ends the ask. The chat pages
never arm the engine's first-name modal (`CtoChatsController` → `skip_first_name_modal!`;
`ApplicationController#first_name_modal?`); every other page still does.

## The status card's sub-labels and ETAs

Each lit pill on the card (`AppDevopsStages`, `agent_chats/_devops_stages`) carries a second
line for where its furthest-along task is, and a third for how long that step usually has
left (`AppDevopsStages::Eta`). Each list row says the same for its own task.

| Task step | Pill | Sub-label | ETA |
|-----------|------|-----------|-----|
| `designed` | Building | Prepping | "no builder" unless a launcher is live, else the usual wait |
| only `designed` in the lane | **Prepping**, no count | none | the usual wait while a launcher is live, else none ("waiting for a builder" stays on the row) |
| `building` | Building | Building (On hold while blocked) | usual build time, less time spent; a first version reads the launcher's own runs |
| `submitted` | Building | Reviewing | usual review time |
| `reviewed` | Building | Approved | usual wait for a release |
| `assembled` | Releasing | On QA | usual time to ship |
| release deploying | Deploying | Going live | usual production deploy |

- **The usual time** is the median `seconds_in_from` of the last 20 forward transitions out of
  that stage (`task_events`), board-wide, cached ten minutes; Deploying uses the last 20
  releases' `prod_deploy_started_at → shipped_at`. With fewer than three durations the pill
  shows no ETA.
- **The countdown** (task `live-build-countdown`). A step with a real start (every step but
  `designed`, whose `created_at` is no start) carries its expected finish, the step's start
  plus the usual time, as the pill's `data-deadline`. The pill paints the clock to it,
  `05:48` (`1:02:03` from an hour up; `Eta.clock`), in tabular numerals, and
  `app/javascript/devops_countdown.js` ticks it each second, reduced motion included (it is
  text). Past the deadline it reads "Any minute now", never a negative. The ticking span is
  hidden from screen readers, which hear the rounded wait once ("~6 min left"); the list row
  keeps the rounded words ("Building · ~6 min left", "taking longer than usual"). Prepping and
  "no builder" keep their words, with no countdown.
- **A client build's usual time** is the launcher's own record, not the board's: the median
  `started_at → finished_at` of the last 20 `devops.client_build` runs that ended
  `preview_ready` (the builder's wall clock; a failed or released run built nothing), and
  `typical_build_minutes` in `config/client_builds.yml` (8) until one has. The hub's
  `building → submitted` median is PR work, about half an hour, and a first version's own
  move is `building → shipped`, which that median never reads. A building client build counts
  down from its run's `started_at`.
- **The launcher seam.** A designed task promises minutes only while a dispatcher ping
  (`AgentDispatcher`) carrying the soul `client-build-launcher` has been heard in the last five
  minutes and is not paused (`Eta.launcher_live?`).
- **The preview seam.** A `preview_ready` checkpoint `TaskEvent` on a task past `designed` and
  still in the Building lane reads "Preview ready", with no ETA (task `client-app-host`).

Build My App on the summary card launches first, then goes to the chat. The launch sets
`app_ctos.launch_animation_pending` (the app's initial load), and the owner's first visit to
the chat (`CtoChatsController#show`), however they arrived (the signed-in press, the magic
link, Google), clears it atomically and renders the launch panel (`build/_launch`) instead:
the new CTO's portrait (morphing from Alex's), the app's name, and three steps ("Building
Brand Sheet", "Hatching CTO", "Setting Up Domain") resolving over about eight seconds in the
app's colours, before a Turbo visit to the same chat, where the portrait morphs into the
chat's head. A reload is the chat; an admin viewing someone else's app never sees or spends
the flag; a Turbo hover prefetch gets a 204. A refused launch stays on the summary card with
its reason. In development, an admin can replay the panel
for a launched app at `/build/launch-demo/<sub>`. The dispatcher never claims the row; the persona tells the CTO
not to greet again. The chat renders the handover as Alex's turn, then the greeting as the
CTO's.

## Intake files (`AppIntakeMove`)

Files dropped while talking to Alex live under `intake/<request token>/`. After the launch
commits, `AppIntakeMoveJob` moves each Active Storage blob whose key has that prefix to
`apps/<sub>/intake/<rest>`: copy the object (R2 server-side copy on the S3 service), repoint
the blob's key, delete the old object. A crash before the repoint leaves the blob readable
on its old key; one after it leaves only an orphan under `intake/`, which the 30-day intake
sweep removes. The move is idempotent: a moved blob no longer matches the prefix.
