# App Templates — the base app and the web3 bolt-on

**Decided by Mr. McRitchie, 2026-08-31.** Every McRitchie app is built from one
template. A Solana app adds a second on top. This file records the decision *and
the argument behind it*, because a rule stated without its reasoning gets
relitigated the first time someone finds it inconvenient.

## The two templates

| Template | Repos | Applies to |
|---|---|---|
| **BASE** | `studio-engine` + `mcritchie-studio` | **Every** app — web2 and web3 alike |
| **WEB3 ADD** | `solana-studio` + `turf-monster` | Bolted on **only** for a Solana application |

Turf Monster is **not** a separate lineage. It is built on `studio-engine` and
inherits every base primitive; it is unique in carrying web3 **and** payment
rails, which is what makes it the **web3 hub** — the reference app a new Solana
app follows — rather than an exception to the base template.

A naming caution, because this doc uses both: **"the hub" alone means
`mcritchie-studio`**, the web2 flagship. Turf Monster is the hub *for web3 apps*.
They are different apps and the two senses are easy to collide.

McRitchie Studio and McRitchie Industries carry **no on-chain component**.

## Why

Most apps are web2. Standing up web3 infrastructure to build a newsletter app is
wrong, and the base template should stay small enough that a new app is cheap.

## This is not a new rule — the code already said it, then drifted

The engine's capability list already encodes this split. `Studio.features` is a
coarse capability switch defaulting to `[]` — every capability **off**. Its real
values are `:web3`, `:leveling` and `:age_gate`; turf-monster declares
`%i[web3 leveling]` and the hub declares nothing at all. The comment beside the
accessor in `studio-engine/lib/studio.rb` names the case outright:

> feature off (e.g. McRitchie Studio, which ships neither).

Keep `Studio.features` distinct from `Studio.auth_methods`. They are separate
accessors with separate values — `auth_methods` carries `:magic_link`, `:google`,
`:wallet`, `:password`, and `:solana` is not a valid value of either. The auth
modal is the one place they combine, requiring `auth_method?(:wallet)` **and**
`feature?(:web3)` before it offers a wallet.

Alongside that, `studio-engine`'s `README` and `docs/NEW_APP_SETUP.md` have
printed `config.auth_methods = %i[magic_link google]` as the new-app line **since
0.5.2 (2026-06-13)** — a wallet is the addition you opt into, not the default you
strip out.

So the architecture was already the documented intent, and had been for two and a
half months before it was stated as a decision. What drifted was the code: the
hub declares `%i[magic_link google wallet]` today, and the engine shipped web3
view code to every consumer. The tasks below close that gap. Read this as
*restoring* a documented intent, not imposing a new constraint.

## What was decided, and the reasoning that survived scrutiny

### 1. McRitchie Studio drops wallet authentication

Its users are three admins; magic-link plus Google covers them. Wallet sign-in
there cost a mobile deep-link path, a cluster declaration, an env var and a boot
guard, and bought nothing.

[`declare-hub-solana-cluster`](https://mcritchie.studio/tasks/declare-hub-solana-cluster)
was **archived** on this basis — it asked whether the hub signs against mainnet
or devnet, and that question only exists if the hub does wallet auth at all. Its
premise died with the decision.

### 2. The signing console moves to turf-monster — and the counter-argument that lost

**Record the losing argument too.** It was serious, and a future reader who
re-derives it deserves to know it was weighed rather than missed.

**The argument for keeping the console in the hub** was an air gap. Turf Monster
holds custodial keys — `users.encrypted_web2_solana_private_key`, encrypted under
`MANAGED_WALLET_ENCRYPTION_KEY` (OPSEC-015). The hub holds none. So in the hub
the console's keyless property is **structural** — there is no key there to
steal. Move it to turf and that same property becomes merely **conventional**:
true only as long as nobody wires the two together.

**Mr. McRitchie overruled it**, and the reasoning is sound: the real opsec vector
is **session management**. An application boundary that a stolen session walks
straight past is not a security control. Splitting the console from the wallet
app buys a property that reads well on an architecture diagram and stops nothing
an actual attacker would do. Anything wallet-based belongs in the wallet app.

### 3. The control that actually matters — and it is missing

This one outranks placement, and it sequences **before** the console move.

The signer page shows the operator an **opaque byte blob**. Three facts compound:

- It calls `phantom.signMessage`, so Phantom's own transaction preview **does not
  apply** — the wallet cannot tell the signer what they are approving.
- The **Simulate** button proxies through **the same server that built the
  message**. A compromised builder simulates its own lie.
- Therefore two signers approving the same falsified screen is **one lie signed
  twice**.

**Multisig does not defend against a compromised message builder.** It defends
against one signer going rogue, which is a different threat. Until the signer can
verify the message independently of the server that composed it, adding signers
adds no assurance.

### 4. chain-ops is deprecated

It is the third consumer of `solana-studio` and is being wound down separately.

## Do not record these as fact

Two claims are **false** and have already been asserted in conversation. They are
listed here so the correction outlives the error.

| Claim | Reality |
|---|---|
| "The hub has no wallet sign-in." | **It does.** The hub's `config/initializers/studio.rb` declares `%i[magic_link google wallet]`, and its `config/routes.rb` calls `Studio.routes(self)`. The engine draws `/auth/solana/nonce`, `/auth/solana/verify` and `/auth/phantom/callback` behind `Studio.draw_auth_routes && Studio.auth_method?(:wallet)`, and the hub passes both gates — so `bin/rails routes` lists all three today, served by the engine's own `SolanaSessionsController`. Dropping it is *pending work*, not the current state. |
| "turf-vault has an automated deploy path." | **It does not, and must not.** The repo carries no `.github/` at all. Program deploys stay deliberate and manual under the Squads upgrade authority. |

## Implementing tasks

These carry the specifics. **Read the task, not a summary of it** — restated
detail drifts from the work it describes.

Stages are deliberately **not** listed — the board owns them and they move (one
of these advanced a stage while this file was being written). Follow the link.

| Task | What it does |
|---|---|
| [`gate-solana-routes-on-wallet`](https://mcritchie.studio/tasks/gate-solana-routes-on-wallet) | Engine draws Solana routes only for a wallet app. Carries the fullest statement of the decision. |
| [`drop-hub-wallet-auth`](https://mcritchie.studio/tasks/drop-hub-wallet-auth) | McRitchie Studio's `auth_methods` → `%i[magic_link google]`. |
| [`move-web3-modals-to-solana`](https://mcritchie.studio/tasks/move-web3-modals-to-solana) | Web3 modals ship from `solana-studio`, not the engine. |
| [`lint-web2-app-boundary`](https://mcritchie.studio/tasks/lint-web2-app-boundary) | Makes the boundary **enforced** rather than observed. |
| [`declare-hub-solana-cluster`](https://mcritchie.studio/tasks/declare-hub-solana-cluster) | Archived: its premise died with the decision. Kept as the record of why. |

## Not yet filed

Three pieces of this decision have **no task on the board** as of 2026-08-31.
Named here so the gap stays visible instead of being mistaken for finished work:

- **Signer verification** (§3) — the missing control. It **sequences before** the
  console move; filing the move first would ship the weaker ordering.
- **The signing console move** to turf-monster (§2).
- **chain-ops deprecation** (§4).

## Related

- `docs/ECOSYSTEM.md` — the repo map and dependency graph.
- [`new-app-onboarding-sop.md`](new-app-onboarding-sop.md) — the *other* axis:
  managed satellite vs standalone. Orthogonal to this one. A new app picks a
  tier there and a template here.
- [`../modules/app-registry.md`](../modules/app-registry.md) — the registry
  contract and the promotion lifecycle.
