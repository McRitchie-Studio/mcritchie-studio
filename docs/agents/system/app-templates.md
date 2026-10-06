# App Templates — the base app and the web3 bolt-on

Every McRitchie app is built from one template; a Solana app adds a second on
top. Decided by Alex on 2026-08-31 (fullest statement:
[`gate-solana-routes-on-wallet`](https://mcritchie.studio/tasks/gate-solana-routes-on-wallet)),
and enforced by a test in this repo since
[`lint-web2-app-boundary`](https://mcritchie.studio/tasks/lint-web2-app-boundary).

## The two templates

| Template | Repos | Applies to |
|---|---|---|
| **BASE** | `studio-engine` + `mcritchie-studio` | **Every** app, web2 and web3 alike |
| **WEB3 ADD** | `solana-studio` + `turf-monster` | A Solana application **only** |

Why: most apps are web2. Standing up web3 infrastructure to build a newsletter
app is wrong, and the base template stays small so a new app is cheap.

Names: **"the hub" alone means `mcritchie-studio`**, the web2 flagship. Turf
Monster is the reference app a new Solana app follows; it is built on
`studio-engine` like every other app, not a separate lineage. McRitchie Studio
and McRitchie Industries carry no on-chain component. The catalog of apps and
their status is `docs/ECOSYSTEM.md`.

## Where an app declares which template it follows

`Studio.features`, the `features` accessor in studio-engine's `lib/studio.rb`, is
the engine's capability switch. It defaults to `[]`, every capability off, and an
app turns on what it ships in its `config/initializers/studio.rb`. The values read
today are `:web3` (the wallet button in `solana-studio` and the engine's style
gallery), `:leveling` and `:age_gate` (engine surfaces).

- `turf-monster/config/initializers/studio.rb` declares `config.features = %i[web3 leveling]`.
- The hub's `config/initializers/studio.rb` declares no `features` at all. **A web2
  app is the absence of `:web3`** from `Studio.features`; that is the whole signal.

`Studio.auth_methods` is a separate knob: which credentials the login accepts
(`:magic_link`, `:google`, `:wallet`, `:password`). The engine default and the hub's
declaration are both `%i[magic_link google]`; turf-monster declares
`%i[magic_link google wallet]`. `Studio.routes` draws the Solana sign-in routes
(`auth/solana/nonce`, `auth/solana/verify`, `auth/phantom/callback`) behind
`Studio.draw_auth_routes && Studio.auth_method?(:wallet)`; the wallet button that
`solana-studio` contributes to the auth modal defaults to showing only when
`auth_method?(:wallet)` and `feature?(:web3)` both hold. A wallet app opts into
both knobs.

## Enforced, not observed

`lib/web2_app_boundary.rb` and `test/lib/web2_app_boundary_test.rb` assert the
rule on every CI run of this repo, so it fails on the tree rather than waiting for
someone to re-read this page.

- The signal is the booted `Studio.features`; the dependencies are Bundler's own
  parse of the Gemfile (`Bundler.definition.dependencies`), never a grep for
  "solana". This repo names the `solana-studio` **repo** throughout its
  managed-app registry, and a substring guard would flag every mention.
- `Web2AppBoundary::WEB3_GEMS` is `%w[solana-studio]`. An app that does not
  declare `:web3` and declares one of those gems is an `:undeclared_web3_gem`
  violation.
- `Web2AppBoundary::ALLOWLIST` is **empty**, and the hub passes structurally: its
  Gemfile carries `studio-engine` and no `solana-studio`. Keep the machinery. An
  entry, when an app needs one, is audited on every run and any audit goes red
  alone: at least one `justified_by` path must still exist (`:stale_exemption`;
  none listed is `:unjustified_exemption`), it must name a `clearing_task` or an
  `unfiled_reason` (`:nameless_exemption`), its `doc` must exist
  (`:missing_doc_pointer`), and the app must still carry the gem
  (`:obsolete_exemption`). The unit tier covers every audit over fixtures; the
  integration tier proves the check still bites the real tree.
- The guard speaks for the repo it runs in, because CI checks out no sibling
  repo. Only the hub carries it today; a sibling app that wants the same
  enforcement copies the lib and its test.

## What a new app does

1. Pick a tier in [`new-app-onboarding-sop.md`](new-app-onboarding-sop.md),
   managed satellite or standalone. That is the other axis, orthogonal to this one.
2. Take the BASE template: `gem "studio-engine"`, `config.auth_methods =
   %i[magic_link google]` (the new-app line in the engine's `README.md` and
   `docs/NEW_APP_SETUP.md`), and no `features` line. Ship the engine's site footer
   and any legal pages from the first build
   ([onboarding § 7](new-app-onboarding-sop.md#7-build-conventions)).
3. For a Solana app only, add the WEB3 ADD: `gem "solana-studio"`,
   `config.features = %i[web3]`, `config.auth_methods = %i[magic_link google wallet]`,
   and follow turf-monster's patterns.
4. Never add `solana-studio` to a web2 app. Declare `:web3` or drop the gem; the
   boundary guard accepts nothing in between.

## Signer facts live in turf-vault

The turf-vault program's upgrade authority (a Squads vault PDA) and the vault's
signer set are different authorities, and each is per cluster. Read them from
`turf-vault/docs/CURRENT_DEPLOYMENT.md`, under the `## Mainnet` or `## Devnet`
heading you mean, and confirm against the chain. This page restates none of them.

## History

The hub once carried `solana-studio` for an admin signing console and held the
boundary's only allowlist entry. The console, the gem and the entry left together
on 2026-09-04 ([`retire-signing-console`](https://mcritchie.studio/tasks/retire-signing-console)).
The full record, with the losing argument, the console's freeze and removal, the
signer-verification gap and the implementing tasks, is frozen verbatim in
[`../archive/app-templates-2026-10-05.md`](../archive/app-templates-2026-10-05.md).

## Related

- `docs/ECOSYSTEM.md` — the repo map and dependency graph.
- [`new-app-onboarding-sop.md`](new-app-onboarding-sop.md) — managed satellite
  vs standalone; a new app picks a tier there and a template here.
- [`../modules/app-registry.md`](../modules/app-registry.md) — the registry
  contract and the promotion lifecycle.
