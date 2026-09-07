# Modal Lifecycle — build in the app, graduate to the gem

A modal starts life in the app that needs it and, if a second app needs the same
shape, moves into a gem. This module is the standing rule for both halves: what a
new modal MUST compose on day one, and the trigger + procedure for promoting a
piece of it.

**The problem it solves.** Every primitive the design system owns today was
extracted only AFTER it had been copied several times. `blocks/_rail_row`'s own
header records "this markup appears TEN times across three files"; `blocks/_close_x`
records EIGHT. Nobody chose that; each copy was individually reasonable and the
tenth looked like the first. The house wallet row is in that pre-graduation state
right now — hand-rolled in turf-monster's `modals/_wallet_setup`, again in
solana-studio's `solana_studio/modals/_wallet_connect`, and a third time in any new
card that needs it.

## The two gems, and why the split is not a preference

| | Owns | Bundled by |
|---|---|---|
| **studio-engine** | BASE chrome — the modal host, the blocks, the templates, the living style guide. **Ships no wallet UI.** | every **engine-mounting** app (five) |
| **solana-studio** | The WEB3 add — wallet connect, step-up, network mismatch, the deep-link partial | only the web3 apps |

**Among the apps that mount the engine, only turf-monster bundles
solana-studio.** Measured from the lockfiles 2026-09-06. The engine-mounting set
is five: mcritchie-studio, turf-monster, acquisition-studio,
mcritchie-industries, moms-app. Of those, acquisition-studio,
mcritchie-industries, moms-app and **mcritchie-studio itself** carry no
solana-studio. So a primitive that needs the gem and lands in the engine is a
missing-template 500 for four of the five engine-mounting apps — including the
hub.

**Scope both halves to that set** — neither is an ecosystem-wide fact. rolio
mounts neither gem, and **chain-ops bundles solana-studio (0.5.7) without the
engine**, so "only turf-monster has solana-studio" is false across the ecosystem
and true exactly where this rule applies. The conclusion is unchanged; the set it
ranges over is what needed saying.

The style guide already resolves this at RUNTIME rather than build time: it
asks `lookup_context.exists?("wallet_connect", ["solana_studio/modals"], true)`
and lists gem-backed specimens as unopenable where the gem is absent.

**The test is DEPENDENCY, not subject matter**, and that distinction is the whole
rule. Dependency has **two axes**, and a piece goes to solana-studio if EITHER
fires:

- **Render-time** — does it need **solana-studio code to render**?
  → **solana-studio**
- **Runtime** — does it bind to a **wallet/chain JS runtime the base apps do not
  ship** (`window.walletProvider`, `window.solanaConnectAndVerify`), *even when
  its ERB is pure locals*? → **solana-studio**
- Neither — renders entirely from **caller-supplied locals**, against JS every
  app already has? → **studio-engine**

**The runtime axis is not hypothetical, and the render-time axis alone gets it
wrong.** solana-studio's `solana_studio/modals/_wallet_connect` and
`_web3_step_up` take every input through `local_assigns.fetch`, so a locals-only
test reads both as engine-bound. They are not: they bind at runtime to
`window.walletProvider` / `window.solanaConnectAndVerify`, host JS the gem does
not ship. `_web3_step_up` says so in its own header — "CONTRACT WITH THE HOST'S
JS". The implementation lives in `turf-monster/app/javascript/wallet_provider.js`,
while the gem's entire shipped JS tree is one file, `network_guard.js`. A base app
rendering either would paint a picker wired to nothing: a silent dead card, which
is harder to catch than the 500 the render-time axis produces.

A subject-matter rule ("anything wallet-shaped goes to solana-studio") reads
better and is wrong: the engine already owns `blocks/_wallet_brand_sprite`, whose
header says OWNED BY THE ENGINE while it depicts Phantom, Solflare and Backpack —
plus `blocks/_solana_tx_link` and `blocks/_onchain_success`. None needs the gem
and none binds to host wallet JS, so they belong exactly where they are.
(`_solana_tx_link` and `_onchain_success` draw chain-shaped things from locals.
`_wallet_brand_sprite` takes **zero** locals — it is a static `<defs>` of four
`<symbol>`s with no output ERB at all, which is why it is safe everywhere.) A rule
that needs three memorised exceptions is the judgment call it claims to remove;
the two-axis dependency test classifies all of them without one, and it reproduces
the real constraint — a gem dependency is what 500s a base app, and a missing JS
global is what silently deadens one.

## Building a new modal — day one

A new modal lives in the consumer at `app/views/modals/_<name>.html.erb`, and it
**composes the primitives that already exist** rather than re-drawing them.

**Blocks** (`studio/modals/blocks/`): `age_gate` · `birthday` · `card_header` ·
`change_username` · `close_x` · `cta_redirect` · `digit_reel` · `entry_confirmed` ·
`error_card` · `free_entry_earned` · `leveling_activity` · `onchain_success` ·
`processing_card` · `progress_countdown` · `progress_pill` · `rail_row` ·
`seeds_bar` · `shell` · `solana_tx_link` · `success_card` · `wallet_brand_sprite`

**Templates** (`studio/modals/templates/`) — copy-from archetypes: `action` ·
`form` · `status` · `success` · `wizard`

Four rules that are not style preferences — each has cost real breakage:

1. **Single root element.** Every modal is registered inside a `<template x-if>`,
   which keeps exactly one child. A sibling of the root is dropped silently —
   including a sprite whose `<use>` then paints nothing, with no error anywhere.
   (*Whose* `x-if`? Yours. The CONSUMER writes the per-modal one, keyed on
   `$store.modals.current().id === '<id>'`. The host has an `x-if` of its own, but
   it wraps the backdrop and card ONCE per host render and exists to guarantee
   `current()` is non-null inside your registration — it is not the wrapper your
   modal gets. The one-child rule binds either way; only the attribution changes.)
2. **Never re-draw a block.** If `close_x` exists, render it. `_wallet_setup`
   hand-rolled its close mark from 2026-08-11 until 2026-09-05 while the engine
   homed the identical mark for eight other modals from 2026-08-25; the shapes
   drifted because nothing made them share. (A comment in that file says "eight
   months"; the dates say 25 days. The point stands, the number did not.)
3. **Specimens show STRUCTURE, never VALUES.** When adopting a primitive, take
   every value — icon, label, data hook — from the markup you are REPLACING. An
   adopter once carried a specimen's `U+1F39F` across where the app had always
   drawn `U+1F3AB`, landing the wrong glyph on the primary rail of a payment card.
   CI was 6/6 green and no assertion anywhere pinned it.
4. **Register a specimen the same day.** A consumer modal with no entry in
   `/admin/style#modals` is invisible to the design system: nobody browsing the
   guide learns it exists, and the next person builds it again. See below.

### Testing a modal, honestly

Component tests that assert inlined JS **source text** prove the string shipped,
not that the branch works — they cannot kill a mutant that negates a condition.
Measured 2026-09-06 across two PRs: 25 mutants, **10 survived**, including
negating a guard, `||`→`&&`, and `throw`→`console.warn`.

- **Markup and wiring** — a component test is the right tier.
- **Behaviour in inlined JS** — only an e2e spec sees it. If you cannot afford
  one, say the coverage is structural and do NOT report it as mutation-checked.
- When you do mutate, **negate and reorder**, never only delete.

## The graduation trigger

Promote when **either** is true, and not before:

- **A second app has ALREADY rendered the same shape.** Not "will need" — a
  forecast is the judgment this rule exists to remove. One consumer is a modal;
  two that both ship it is a primitive.
- **The same markup exists three times in one app.** Three is where copies stop
  being noticed. Waiting for ten is how ten happened.

Do NOT promote a modal because it feels reusable. An app-specific FLOW stays in
the app even when its chrome is shared — the style guide states the split for the
wallet card exactly: the engine owns the shell, progress pill and brand sprite,
while extension detection, the walkthrough video, the guide route and the
managed-wallet fallback stay in the host.

**Promote the PIECE, not the card.** What graduates is usually a block the card
composes, not the whole modal.

## Graduating — the procedure

The fast lane cannot drive gems (`bin/task begin` refuses on all of them), so the
gem half is hand-branched.

**The gem half is a task like any other.** There is no size exemption for a gem,
and `bin/task begin` refusing one is not permission to skip the board — `begin`
cannot allocate the WORKTREE, but `bin/task create` works, and
`config/feature_shapes.yml` ships a `library` shape for exactly this (tiers:
unit + integration, where integration means the consumer CI suite passes in both
consuming apps). Cut the desk by hand with `git worktree add`.

```bash
# 1. GEM — its own task, hand-cut desk off the shared base
cd /Users/alex/projects/mcritchie-studio
bin/task create --title "<3-5 words>" --repo <studio-engine|solana-studio> \
  --kind chore --shape library --agent <soul> --no-claim
cd /Users/alex/projects/<studio-engine|solana-studio>
git fetch origin && git worktree add .worktrees/<slug> -b feat/<slug> origin/accepted
#    move the partial to studio/modals/blocks/_<name>.html.erb (or
#    solana_studio/modals/), giving it LOCALS for everything the consumers differ on
#    add a specimen: app/views/style/modals/_ds_<name>.html.erb, registered in
#    style/_modals.html.erb at TWO sites — the content template AND the gallery
#    card. One without the other is a card that opens nothing, or a modal
#    nobody can reach from the guide.
#    do NOT set the gem version — the RELEASE owns it (see below)

# 2. CONSUMER — one task, the normal cycle
cd /Users/alex/projects/mcritchie-studio
bin/task begin --title "Adopt <Name> Primitive" --repo <app> --agent <soul> \
  --kind chore --shape ui-only
bin/task update <adoption-task> --depends-on <gem-task>
#    ^ optional: the release then sequences the gem task before this one
#    the qa-release sweep publishes gem versions, bumps consumer LOCKS, and
#    re-pins the Gemfile when the new version ESCAPES the constraint
#    record WHY in the pin comment — the floor is what broke below it, not the
#    number; a trailing comment SURVIVES an automated re-pin
#    replace the local markup with a render call, DELETE the local copy
#    values come from the markup being replaced, never from the specimen
```

**Never hand-set the gem version — declare the bump instead.** "Release, then
note the new version" is a REFUSED instruction: `bin/dor-check` (default gate
`merge`, the one you run at handoff) exits 1 on any diff touching a release-owned
gem version file, because "a version belongs to the RELEASE, not to any one PR …
The release conductor sets it during the sweep." N pull requests riding one
candidate publish exactly ONE version, so a PR that sets one either re-claims a
published version or collides with a sibling. The move the procedure needs is the
one dor-check names:

```bash
bin/task update <slug> --gem-bump major     # patch|minor|major; an OVERRIDE, never required
```

This bites twice here, because step 1 prescribes `--kind chore` — and a chore that
REMOVES or RENAMES a partial consumers render is exactly the breaking-chore case
`--gem-bump` exists for. `Release::GemVersion::KIND_BUMPS` maps `chore` to
`patch`, so left undeclared the sweep publishes a **patch** for a change that
breaks every consumer below it. (A `breaking` risk tag forces `major` too — the
precedence is explicit override, then a breaking tag, then the kind's default — so
either move works; what does not work is silence.)

**`--depends-on` declares the sequence; it is usually optional here.** The
column is real (`db/schema.rb`) and really read — `Release::Ordering.producer_first`
topologically sorts on it, reached from `Release#ordered_members` and the
conductor's sweep — and as of /tasks/wire-task-dependencies-field a command
finally writes it. Until then nothing did: an earlier draft of this procedure
told you to declare the field in a bracketed literal syntax nothing parsed, so
the step named a behaviour no one could perform.

Reach for it only for a sequence the heuristic cannot infer. `producer_first`
already sorts gems before apps unaided, which is exactly the gem-then-consumer
case above, so the normal graduation needs no edge at all — one app that must
deploy before another is the case that does. Three properties before you lean
on it: a dependency on a task OUTSIDE the release does not hold this one back
(by design — it cannot be ordered here); a slug naming NO task is REFUSED,
precisely because that same tolerance would otherwise make a typo invisible
forever; and the flag REPLACES the list rather than appending, so pass the whole
set in one call.

**Three things that bite here:**

- **The pin string is not the floor.** A two-segment `~>` admits anything below
  1.0, so `~> 0.62` silently resolved 0.65 while everyone read "we're on 0.62".
  **That misreading is recorded SEVEN times on a single line** —
  turf-monster's `studio-engine` pin comment, where six floor notes each end
  "…already admitted X and this bump is invisible to the resolver — it is the
  FLOOR that moved", and a seventh records the pin "documenting history rather
  than the floor". Not twice: seven, in one comment, each written by someone who
  had just been bitten. turf-monster's `test/lib/engine_pin_contract_test.rb`
  asserts the DERIVED floor so a `bundle update` walking backwards fails there
  instead of at runtime — an app adopting a primitive should extend it, not just
  move the pin.
- **The floor pin is only *sometimes* a human decision.** Raising a floor the
  resolver ALREADY satisfies is yours — the sweep sees a version its constraint
  admits, calls it `:lock_only`, and leaves your pin string untouched, so nothing
  automated will ever record the floor for you. But when a published version
  **escapes** the constraint upward, `Release::ShipSequence.consumer_bump_action`
  returns `:rewrite_pin` and `Release::GemfileRepin.rewrite_pin` rewrites the line
  itself. Say which case you are in rather than assuming the pin is inert.
  **A WHY comment survives that rewrite**: `rewrite_pin_line` captures the trailing
  comment and re-emits it with the new constraint, so the reason you record is not
  lost to an automated re-pin — which is exactly why recording it is worth the
  keystrokes.
- **A consumer assertion can red-seal the producer.** A consumer test that pins a
  path inside the gem blocks the gem's own publish. Assert behaviour, not
  the gem's internal layout.

## Where this sits

`building-sop.md` covers the feature-agent build flow; this module is the modal
specialisation of it. The design system itself is the living style guide at
`/admin/style#modals`, which is the catalogue — read it before building a modal,
and add to it after.
