# Client pipeline and building lanes

An app's owner sees that app's work on the board, sanitized, at
`/applications/:slug/pipeline`; and a client app's tier caps how many of its tasks
build at once. Plan: Phase 8 of `.agents/epics/domain-agents.md` (Alex McRitchie,
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
- **Lanes:** Prepping (`designed`, the status card's word for it; numbered in board order: rank, then newest
  first; the number is display only, and nothing makes #1 start next), Building, In review
  (`submitted`), Ready for QA (`reviewed`), On QA (`assembled`), Shipped (the last
  14 days). Each card shows its title, its lane and its time in that lane.
- **Building lanes:** "2 of 3 lanes in use" and a meter, from the app's tier
  (below). A send-back keeps its lane and a downgrade evicts nothing, so the
  count can run past the cap: it then reads "3 lanes in use on a 2-lane plan",
  draws the extra lanes in the warning tone, and says why.
- **Tonight's ship:** a labelled preview. It reads the release in progress
  (`Release.current`): its state and how many of this app's tasks ride it. The
  nightly ship times and per-app release trains are separate Phase 8 tasks.

### The sanitizer

A non-admin's card is built from an allow-list (`ClientPipeline::OWNER_FIELDS`):
title, lane, time in lane, a neutral role (**Builder** while building,
**Reviewer** in review), **On hold** for a block, and the queue number. Nothing
else crosses: no slug or task link, PR, agent or soul name, mascot, cost or token
count, reviewer note, session id, repo list, desk path, local URL or other app.

The owner reads a task's title only when its `devops.repositories` is exactly
this app's repo. A task naming any other repo is platform work shared with other
apps, where other clients' names live, so its card reads **Shared platform
work** (Alex McRitchie's default, 2026-10-16). The deny-list scrubber below cannot be
complete; this rule is the structural guard.

A title that crosses is free text an agent wrote, so it is scrubbed too
(`ClientPipeline::Scrubber`): a URL, hostname or filesystem path becomes `[link]`; a
credential mention (a token, key, signer, secret, password, 1Password) replaces the whole
title with **Security maintenance**; a soul's name becomes "the team"; another
app's name becomes "a shared component". The app's own name stays. Product
tokens (entry tokens, level-up tokens, a design system's surface tokens) are
features, not credentials, and stay.

Each lane's count chip and each queue number carry screen-reader words ("2
tasks", "Queue position #1").

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
`BuildingLanes` enforces it as a `Task` validation on the **claim**
(`Task#claims_a_building_lane?`):

- a create at `building`;
- a move into `building` from `designed` (the move `bin/task begin` makes, its
  child `move <slug> building`, and the board's drag), and a reopen from
  `shipped` or `archived`;
- the first move into `building` of a task that was never claimed (created at
  a later stage, so it has no `started_at`), even as a block;
- a client repo added to `devops.repositories` of a task already building
  (checked for the added app only).

Past the cap the board answers 422 with a message naming the app, its tier, the
tasks in its lanes and the next tier up, and the task stays where it was. The
check takes a transaction-scoped advisory lock per capped app before it counts,
so two concurrent claims serialize and cannot overfill the cap by one.

Blocking a `designed` task (`Task#block!` lands it on `building`) is a claim
too: at the cap the block answers 422 with the lane-cap message; under the cap
the blocked task takes a lane. That closes a block-then-unblock way around the
cap.

A multi-repo task counts against every tiered app it names. A hub task that
also names `turf-monster` takes one of Turf's lanes, so once Turf is on a tier,
Alex McRitchie's own Turf work shares that tier's cap.

`bin/task begin` asks first, before it cuts a desk: `GET
/api/v1/tasks/:slug/building_lane` returns the refusal a claim would meet now, or
null, and writes nothing. On a refusal begin stops with that message; on a board
without the endpoint, or any failure, it falls through to the claim.

Never capped: the hub (`BuildingLanes::INTERNAL_APPS`, `mcritchie-studio`) and
any app with no tier. A send-back of a claimed task (a rework block or QA
bounce from `submitted`, `reviewed` or `assembled`) and a re-claim of a task
already building take no new lane.
