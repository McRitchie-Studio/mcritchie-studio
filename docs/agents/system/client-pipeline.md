# Client pipeline and building lanes

An app's owner sees that app's work on the board, sanitized, at
`/applications/:slug/pipeline`; and a client app's tier caps how many of its tasks
build at once. Plan: Phase 8 of `.agents/epics/domain-agents.md` (Alex,
2026-10-16). Who owns which app: [`app-owners.md`](app-owners.md).

## The page

`/applications/:slug/pipeline` (`ApplicationsController#pipeline`,
`ClientPipeline`). Read-only. It is linked from the app page's **Pipeline** card
and, for an owner of one app, from the sidebar's **Your apps** section.

- **Who:** the app's owner or an admin (`AppOwnership.manage_app?`). Anyone else
  gets 404, never 403; a visitor is sent to sign in. An unannounced app
  (`AppCatalog::UNANNOUNCED`) is a 404 to everyone but an admin.
- **Which tasks:** every task whose `devops.repositories` names the app's slug
  (`Task.for_repository`; an App slug is its repo slug). A multi-repo task shows
  on each app it names.
- **Lanes:** Queued (`designed`, numbered in board order), Building, In review
  (`submitted`), Ready for QA (`reviewed`), On QA (`assembled`), Shipped (the last
  14 days). Each card shows its title, its lane and its time in that lane.
- **Building lanes:** "2 of 3 lanes in use" and a meter, from the app's tier
  (below).
- **Tonight's ship:** a labelled preview. It reads the release in progress
  (`Release.current`): its state and how many of this app's tasks ride it. The
  nightly ship times and per-app release trains are separate Phase 8 tasks.

### The sanitizer

A non-admin's card is built from an allow-list (`ClientPipeline::OWNER_FIELDS`):
title, lane, time in lane, a neutral role (**Builder** while building,
**Reviewer** in review), **On hold** for a block, and the queue number. Nothing
else crosses: no slug or task link, PR, agent or soul name, mascot, cost or token
count, reviewer note, session id, repo list, desk path, local URL or other app.

A title is free text an agent wrote, so it is scrubbed too
(`ClientPipeline::Scrubber`): a URL or filesystem path becomes `[link]`; a
credential mention (a token, key, secret, password, 1Password) replaces the whole
title with **Security maintenance**; a soul's name becomes "the team"; another
app's name becomes "a shared component". The app's own name stays.

An admin sees titles as written, each task's link, and its PR link.

## Building lanes per tier

`building_lanes` sits beside each tier's price in `config/workspace_packages.yml`:

| Tier | Lanes |
|------|-------|
| Vibe | 1 |
| Builder | 2 |
| Pro | 3 |
| Team | 4 |
| Enterprise | blank (unlimited) |

The app's tier is `apps.package_tier`, which an admin sets on the app page.
`BuildingLanes` enforces it as a `Task` validation on the **claim**: a create at
`building`, or a move from `designed` to `building`. That is the move `bin/task
begin` makes (its child `move <slug> building`) and the board's drag. Past the
cap the board answers 422 with a message naming the app, its tier, the tasks in
its lanes and the next tier up, and the task stays in `designed`, in order.

`bin/task begin` asks first, before it cuts a desk: `GET
/api/v1/tasks/:slug/building_lane` returns the refusal a claim would meet now, or
null, and writes nothing. On a refusal begin stops with that message; on a board
without the endpoint, or any failure, it falls through to the claim.

Never capped: the hub (`BuildingLanes::INTERNAL_APPS`, `mcritchie-studio`) and
any app with no tier. A rework bounce (a submitted task blocked back to
`building`) and a re-claim of a task already building take no new lane.
