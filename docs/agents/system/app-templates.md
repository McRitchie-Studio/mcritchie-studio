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
half months before it was stated as a decision. What drifted was the code: at the
time of the decision the hub declared `%i[magic_link google wallet]`, and the
engine shipped web3 view code to every consumer. The tasks below close that gap —
[`drop-hub-wallet-auth`](https://mcritchie.studio/tasks/drop-hub-wallet-auth)
closed the hub's half the same day. Read this as *restoring* a documented intent,
not imposing a new constraint.

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

Two claims were asserted in conversation and were **false when asserted**. They
are listed here so the correction outlives the error.

| Claim | Reality |
|---|---|
| "The hub has no wallet sign-in" — offered as a *reason* for the decision. | **It had one.** When the decision was made, `config/initializers/studio.rb` declared `%i[magic_link google wallet]` and `config/routes.rb` called `Studio.routes(self)`. The engine draws `/auth/solana/nonce`, `/auth/solana/verify` and `/auth/phantom/callback` behind `Studio.draw_auth_routes && Studio.auth_method?(:wallet)`, and the hub passed both gates — so `bin/rails routes` listed all three, served by the engine's own `SolanaSessionsController`. The decision had to **remove** wallet auth, not merely decline to add it. [`drop-hub-wallet-auth`](https://mcritchie.studio/tasks/drop-hub-wallet-auth) removed it on 2026-08-31, so the hub has none **now** — as a result of this decision, not as a fact that preceded it. |
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
| [`lint-web2-app-boundary`](https://mcritchie.studio/tasks/lint-web2-app-boundary) | Makes the boundary **enforced** rather than observed. Landed — see [Enforced, not observed](#enforced-not-observed). |
| [`declare-hub-solana-cluster`](https://mcritchie.studio/tasks/declare-hub-solana-cluster) | Archived: its premise died with the decision. Kept as the record of why. |

## Enforced, not observed

The rule above is a test. `lib/web2_app_boundary.rb` + `test/lib/web2_app_boundary_test.rb`
assert it on every CI run of this repo, so it fails on the tree rather than
waiting for someone to re-read this file.

**Where "this app is web2" is declared: the absence of `:web3` from
`Studio.features`.** That is a *read* of the signal described above, not a new
one — the accessor already exists, already means exactly this, and the engine's
own comment beside it already names McRitchie Studio as the app that "ships
neither". The two alternatives lost for concrete reasons, recorded in the seam's
header: a key in `config/release_repos.yml` would put template classification
into a registry whose job is the deploy ladder, and "the absence of the gem
itself" is circular — with no independent claim, an app that adds
`solana-studio` tomorrow would simply redefine itself as web3 by adding it.

Dependencies are read **structurally**, through Bundler's own parse of the
Gemfile, never by grepping for `solana`. That distinction is load-bearing here:
this repo mentions Solana in comments and throughout the managed-app registry
that names the solana-studio **repo** (`app/models/release/repos.rb`,
`ci/app_ladder.rb`, `github_workflow_run.rb`, `release/gem_version.rb`,
`reviewer_selector.rb`). Those are not Solana logic and a substring guard would
flag every one of them.

**Scope.** The guard speaks for the repo it runs in. CI checks out no sibling
repos, so a cross-repo sweep would resolve against whatever happened to be on
disk and pass vacuously in CI — the failure mode
`test/lib/feature_shape_tiers_test.rb` exists to kill. `mcritchie-industries`
and `rolio` already satisfy the boundary today; each carries its own copy when
it wants the guard.

### The hub's exemption, and why it cannot rot

McRitchie Studio **cannot** pass this check today — the admin signing console is
its last real use of the gem, and it stays until the console moves to
turf-monster. So the boundary landed **enforced with one named exemption**
rather than waiting for that move.

The exemption is not a mute. It is an entry in `Web2AppBoundary::ALLOWLIST` that
the same test audits three ways, any of which goes red on its own:

| Audit | Fails when |
|---|---|
| **It must still be needed** | Every path in `justified_by` (the signing console) is gone. The exemption **expires by itself** the moment the console lands elsewhere, telling you to drop the gem and the entry. |
| **It must name its exit** | It names neither a `clearing_task` slug nor an explicit `unfiled_reason`. An exemption pointing at nothing is itself a violation. |
| **It must still describe a real violation** | The app no longer declares the gem, so the entry is obsolete and must go. |

**The clearing task does not exist yet, and the entry says so** rather than
pointing at a slug that resolves to nothing. The signing console move is one of
the three unfiled pieces below, and it **sequences after** signer verification
(§3) — filing the move first would ship the weaker ordering. When it is filed,
put its slug in the entry's `clearing_task`.

## Not yet filed

Three pieces of this decision have **no task on the board** as of 2026-08-31.
Named here so the gap stays visible instead of being mistaken for finished work:

- **Signer verification** (§3) — the missing control. It **sequences before** the
  console move; filing the move first would ship the weaker ordering.
- **The signing console move** to turf-monster (§2). The web2 boundary guard's
  allowlist entry for the hub names this gap explicitly and expires on its own
  once the console leaves; when the task is filed, record its slug there.
- **chain-ops deprecation** (§4).

## Related

- `docs/ECOSYSTEM.md` — the repo map and dependency graph.
- [`new-app-onboarding-sop.md`](new-app-onboarding-sop.md) — the *other* axis:
  managed satellite vs standalone. Orthogonal to this one. A new app picks a
  tier there and a template here.
- [`../modules/app-registry.md`](../modules/app-registry.md) — the registry
  contract and the promotion lifecycle.
