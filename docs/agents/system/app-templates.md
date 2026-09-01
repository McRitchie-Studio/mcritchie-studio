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

### 2. The signing console was to move to turf-monster — SUPERSEDED, see §2a

> **🧊 SUPERSEDED — 2026-08-31, later the same day.** The move is
> **cancelled, not pending** — the console went **on ice** instead, and a frozen
> console has nowhere to move to. Read §2a below before acting on anything in
> this section. The argument is kept because it is still the record of why
> placement was decided the way it was, and because the losing side deserves to
> stay readable — not because a move is queued.

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

### 2a. …and then the console went ON ICE — 2026-08-31, and this is the live state

**Frozen, not removed.** The code stays exactly where it is, in the hub, and
keeps working. Nothing about the console is deprecated or scheduled for deletion.
Mr. McRitchie: *"if it comes up for a purpose we can pick it up then."* The
console's own doc carries the full note — `docs/SIGNING_CONSOLE_V2.md` in this
repo (not linked: the docs route serves only `docs/agents/**`).

**Two consequences for this file, and they are the whole point of §2a:**

- **The move (§2) is not happening.** Not deferred, not unfiled-but-owed —
  **cancelled**. Do not file it, and do not read the hub's boundary exemption
  below as waiting on it.
- **Signer verification (§3) is not happening either.** It was the control that
  had to land *before* the move. With the tool frozen and unused, fixing a
  display gap on it buys nothing, so §3 stands as a recorded **known gap on a
  frozen tool**, not as owed work.

**Why it was frozen** — three facts that only mattered together:

1. **No unique job.** It supports exactly two instructions, `initialize` and
   `update_signers`, and both already have another path: mainnet `initialize`
   runs from `turf-vault/scripts/initialize-mainnet.js` (CLI keypair set to the
   `INIT_AUTHORITY`); program upgrades go through Squads
   (`turf-vault/scripts/squad-upgrade.js`) and never touched the console; and
   contest/treasury operations are 2-of-3 **vault signer** operations that
   turf-monster's own flows handle.
2. **No users.** Zero signing requests in production, one durable nonce on
   devnet — **measured against production on 2026-08-31**, not asserted
   (`SigningRequest.count` → 0; `DurableNonce.pluck(:cluster).tally` →
   `{"devnet"=>1}`; the re-runnable command is in the console's own doc).
   Mainnet sits on turf-vault v0.24 awaiting an upgrade window. It has never
   been used for anything.
3. **The unfixed control gap in §3** — which is **inherited, not new**: the
   retired v1 console (`Admin::SigningController` + `Signing::Cosigner`, retired
   2026-06-02, which also held Mason's key server-side) had the identical
   RPC-proxy shape.

**The one question that would take it off ice.** The console's only genuine
advantage over the scripts is **multi-signer coordination** — N wallets signing
in separate browsers, anchored on a durable nonce so a half-signed transaction
does not expire between signers. No script does that. So: **does Squads cover
rotating the turf-vault 2-of-3 signer set (`update_signers`)?** Squads holds the
program's *upgrade* authority, which is a different thing from the vault's signer
set. **Nobody has confirmed either way.** If it turns out not to be covered, that
is the job only the console does and it comes off ice — answer it before the next
signer-set change, not after.

### 3. The control that actually matters — and it is missing

Recorded as a **known gap on a frozen tool** (see §2a), not as owed work. It used
to sequence **before** the console move; both are moot now that the console is on
ice.

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
| [`ice-the-signing-console`](https://mcritchie.studio/tasks/ice-the-signing-console) | Records the console freeze (§2a) and retires the move (§2) + signer verification (§3) as cancelled, not owed. |

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
its last real use of the gem. So the boundary landed **enforced with one named
exemption** rather than waiting for the console to go somewhere.

**With the console on ice (§2a), that exemption is now open-ended.** The console
is frozen in place, so there is no move to wait on and no date by which the hub
stops carrying `solana-studio`. Read the entry as **permanent until someone
decides otherwise**, not as a countdown. That is a deliberate outcome, not rot:
the audits below still bite, and the one that matters — *it must still be
needed* — retires the entry automatically if the console's files ever do leave.

The exemption is not a mute. It is an entry in `Web2AppBoundary::ALLOWLIST` that
the same test audits three ways, any of which goes red on its own:

| Audit | Fails when |
|---|---|
| **It must still be needed** | Every path in `justified_by` (the signing console) is gone. The exemption **expires by itself** the moment the console's files leave the hub, telling you to drop the gem and the entry. Freezing the console does not trip this — the files are all still there, which is the point. |
| **It must name its exit** | It names neither a `clearing_task` slug nor an explicit `unfiled_reason`. An exemption pointing at nothing is itself a violation. |
| **It must still describe a real violation** | The app no longer declares the gem, so the entry is obsolete and must go. |

**There is no clearing task, and the entry says so** (`clearing_task: nil` plus
an `unfiled_reason`) rather than pointing at a slug that resolves to nothing.
That stays correct after §2a, but for a **different reason than the entry gives**:
the move is not un-filed-and-owed, it is **cancelled**. Do not file it to satisfy
this entry.

> ⚠️ **Known stale prose, in code, deliberately left for a code-shaped change.**
> `lib/web2_app_boundary.rb`'s `ALLOWLIST["mcritchie-studio"]` still reads
> pre-decision: its `unfiled_reason` says the move is *"NOT YET FILED as of
> 2026-08-31; it sequences after signer verification,"* and the comment above it
> repeats that ordering. Both are superseded by §2a. **The guard's behaviour is
> unaffected** — the exit audit is a presence check, so CI is green either way —
> and the entry's own `doc:` key points here, so a reader who follows it lands on
> the correction. Rewriting those two Ruby strings is a code diff and belongs to
> a change that can carry one; this note is the pointer until then.

## Not yet filed

**One** piece of this decision has **no task on the board** as of 2026-08-31:

- **chain-ops deprecation** (§4).

**The other two are not unfiled — they are cancelled.** This section listed three
until the evening of 2026-08-31; both removals are recorded rather than silent,
because "unfiled" and "decided against" look identical from an empty board and
only one of them is work someone should pick up:

| Was listed | Now | Why |
|---|---|---|
| The signing console move to turf-monster (§2) | **Cancelled** | The console is on ice (§2a). A frozen console has nowhere to move to. **Do not file this.** |
| Signer verification (§3) | **Cancelled** | It existed to precede the move and to make the console trustworthy in use. The console has no users and is frozen, so the gap is recorded (§3) rather than closed. **Do not file this.** |

Either would come back only with the console itself — see the reviving question
in §2a.

## Related

- `docs/ECOSYSTEM.md` — the repo map and dependency graph.
- [`new-app-onboarding-sop.md`](new-app-onboarding-sop.md) — the *other* axis:
  managed satellite vs standalone. Orthogonal to this one. A new app picks a
  tier there and a template here.
- [`../modules/app-registry.md`](../modules/app-registry.md) — the registry
  contract and the promotion lifecycle.
- `docs/SIGNING_CONSOLE_V2.md` — the admin signing console this file keeps
  referring to, carrying the full **on ice** note (§2a) beside the code. Written
  as a path, not a link: the docs route serves only `docs/agents/**`.
