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
| **studio-engine** | BASE chrome — the modal host, the blocks, the templates, the living style guide. **Ships no wallet UI.** | every app |
| **solana-studio** | The WEB3 add — wallet connect, step-up, network mismatch, the deep-link partial | only the web3 apps |

**Only turf-monster bundles solana-studio.** Measured from the lockfiles
2026-09-06: acquisition-studio, mcritchie-industries, moms-app and
**mcritchie-studio itself** do not. So a primitive that needs the gem and lands in
the engine is a missing-template 500 for four of the five apps — including the
hub. The style guide already resolves this at RUNTIME rather than build time: it
asks `lookup_context.exists?("wallet_connect", ["solana_studio/modals"], true)`
and lists gem-backed specimens as unopenable where the gem is absent.

**The test is DEPENDENCY, not subject matter**, and that distinction is the whole
rule:

- Does it need **solana-studio code at render or runtime**? → **solana-studio**
- Does it render entirely from **caller-supplied locals**? → **studio-engine**

A subject-matter rule ("anything wallet-shaped goes to solana-studio") reads
better and is wrong: the engine already owns `blocks/_wallet_brand_sprite`, whose
header says OWNED BY THE ENGINE while it depicts Phantom, Solflare and Backpack —
plus `blocks/_solana_tx_link` and `blocks/_onchain_success`. All three draw
chain-shaped things from locals and need no gem, so they belong exactly where they
are. A rule that needs three memorised exceptions is the judgment call it claims
to remove; the dependency test classifies all of them without one, and it
reproduces the real constraint, because only a gem dependency can 500 a base app.

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

1. **Single root element.** The host wraps every modal in `<template x-if>`, which
   keeps exactly one child. A sibling of the root is dropped silently — including a
   sprite whose `<use>` then paints nothing, with no error anywhere.
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
#    style/_modals.html.erb so it is live-openable in the guide
#    release, then note the new version

# 2. CONSUMER — one task, the normal cycle
cd /Users/alex/projects/mcritchie-studio
bin/task begin --title "Adopt <Name> Primitive" --repo <app> --agent <soul> \
  --kind chore --shape ui-only
bin/task update <adoption-task> --depends-on <gem-task>
#    ^ the release then sequences the gem task before this one
#    — the qa-release sweep publishes gem versions and bumps consumer LOCKS
#    itself; the Gemfile FLOOR pin is still a human decision
#    bump the Gemfile pin AND record WHY in the pin comment — the floor is what
#    broke below it, not the number
#    replace the local markup with a render call, DELETE the local copy
#    values come from the markup being replaced, never from the specimen
```

**`--depends-on` is usually optional here.** `Release::Ordering.producer_first`
already sorts gems before apps by itself, so a consumer waiting on a gem is the
case the heuristic gets right unaided. Declare the edge when you want the
sequence stated rather than inferred, or for an order the heuristic cannot see —
one app that must deploy before another. Two properties worth knowing before you
lean on it: a dependency on a task OUTSIDE the release does not hold this one
back (by design — it cannot be ordered here), and the flag REPLACES the list
rather than appending, so pass the whole set in one call.

**Two things that bite here:**

- **The pin string is not the floor.** A two-segment `~>` admits anything below
  1.0, so `~> 0.62` silently resolved 0.65 while everyone read "we're on 0.62".
  That misreading has bitten twice. turf-monster's
  `test/lib/engine_pin_contract_test.rb` asserts the DERIVED floor so a
  `bundle update` walking backwards fails there instead of at runtime — an app
  adopting a primitive should extend it, not just move the pin.
- **A consumer assertion can red-seal the producer.** A consumer test that pins a
  path inside the gem blocks the gem's own publish. Assert behaviour, not
  the gem's internal layout.

## Where this sits

`building-sop.md` covers the feature-agent build flow; this module is the modal
specialisation of it. The design system itself is the living style guide at
`/admin/style#modals`, which is the catalogue — read it before building a modal,
and add to it after.
