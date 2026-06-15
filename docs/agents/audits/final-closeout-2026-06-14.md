# Final Ecosystem Closeout Audit

Date: 2026-06-14
Scope: `/Users/alex/projects` primary checkouts, generated root agent docs, and
high-risk active Markdown surfaces.

## Result

The documentation and agent-operating cleanup is at maintenance mode.

Completed tranches:

1. Active docs trust reset
2. Engine session refactor
3. Shared email operations hardening
4. Solana/Vault verification orientation
5. Managed app registry
6. Final drift closeout

The durable source of truth is now:

- `/Users/alex/projects/AGENTS.md` generated from
  `mcritchie-studio/docs/agents/index.md`
- `mcritchie-studio/docs/ECOSYSTEM.md`
- app-owned README/RUNBOOK/topic docs for app-specific behavior
- `mcritchie-studio/docs/agents/maintenance/delete-later.md` for items that
  look removable but still need approval or salvage

Do not add root `CLAUDE.md` or `CODEX.md` by default. Codex reads `AGENTS.md`
natively. Claude should be tested against `AGENTS.md` before adding a thin
adapter.

## Closeout State

Primary managed repos were clean at closeout check:

- `mcritchie-studio`
- `turf-monster`
- `studio-engine`
- `solana-studio`
- `turf-vault`

Latest closeout check: the primary known repos are clean on `main`, including
`mcritchie-studio`, `turf-monster`, `studio-engine`, `solana-studio`,
`turf-vault`, and `rolio`.

Known preserved worktrees at the initial closeout:

- `turf-vault/.worktrees/grant-seeds-salvage`
- `mcritchie-studio/.worktrees/broadcasts-salvage`

Those were intentionally not deleted during the first pass because they required
human salvage/drop approval.

Salvage/delete follow-up, 2026-06-14: both hidden worktrees were reviewed and
removed. Turf Vault's local `feat/v0.22-grant-seeds` branch was deleted because
it had no commits ahead of `main`. McRitchie Studio's `feat/broadcasts` branch
was retained as historical source material only; the durable broadcast direction
was promoted into `docs/agents/modules/email-operations.md`.

Archive follow-up, 2026-06-14: the remaining delete-later `audit needed` docs
were converted into archive-only context. Turf Monster now has
`docs/TEST_COVERAGE_STATUS.md` as the current test-coverage orientation, while
May 2026 security/refactor/test audit snapshots and old McRitchie system audits
carry archive banners.

Prompt/rehearsal follow-up, 2026-06-14: Claude-era prompt artifacts and the
retired Turf v0.15 devnet rehearsal were removed after durable replacements
were added: `docs/agents/modules/audit-playbook.md`,
`turf-monster/docs/SECURITY_REVIEW.md`, current Turf Solana docs, and the
TurfVault verification matrix.

Claude-file follow-up, 2026-06-14: app-level `CLAUDE.md` files were deleted
after final knowledge-loss review. Durable context now lives in app
README/RUNBOOK/topic docs, with cross-repo agent policy in `AGENTS.md` generated
from McRitchie Studio.

Active/archive docs follow-up, 2026-06-14: current onboarding and runbook docs
were swept for deleted Claude-file references, old port/version patterns, and
SES/Resend drift. Archive candidates were checked for explicit historical
boundaries; the remaining cleanup was limited to Turf Monster's active runbook
and historical test backlog plus SolanaStudio's old security audit banner.

Production deployment follow-up, 2026-06-14: Turf Monster was deployed from the
cleaned baseline to Heroku release `v90` at commit `4333f90`. Stripe checkout is
retired by default with `PAYMENT_PROVIDER=none`; CDP ramp and web2 USDC entry
remain enabled. Production mail uses the verified Resend fallback sender
`McRitchie Studio <team@mcritchie.studio>` while SES production access remains
pending. The Heroku Node build pin was moved from Node 20 to Node 22 across
Turf Monster, CI, and McRitchie Studio's recovery docs/scripts.

Heroku platform follow-up, 2026-06-15: both active Rails apps are now on
Heroku-26. McRitchie Studio release `v59` at commit `bc38c5b` pins Ruby
`3.3.11`, Node `22.x`, and buildpacks `heroku/nodejs` then `heroku/ruby`; web
and Solid Queue worker dynos are up. Turf Monster release `v93` at commit
`37ca6ea` is the Heroku-26 stack migration plus Steffon's CDP/Phantom contest
hardening commit; web and Sidekiq worker dynos are up. Both production `/up`
checks returned `200`.

## Verification On Record

High-signal proof from this cleanup:

- McRitchie Studio and Turf Monster local `/up` checks returned `200` during the
  local stack proof.
- McRitchie Studio and Turf Monster magic-link flows were verified locally; Turf
  Monster local inbox and McRitchie Studio real delivery both worked.
- `studio-engine 0.5.9` was published and adopted by both Rails apps, adding the
  shared `email:smoke` provider proof task.
- Primary local McRitchie Studio and Turf Monster stacks now send real mail
  through Resend while worktree stacks default to local capture; both
  non-production banners show the runtime mail state.
- Turf Monster production release `v93` built with Node `22.22.3`, with
  buildpacks ordered `heroku/nodejs` then `heroku/ruby`; the previous Node 20
  EOL build warning is gone and the app is now on Heroku-26.
- Focused Turf Monster tests for the CDP/Phantom hardening release passed:
  `148 runs, 647 assertions, 0 failures`.
- Turf Monster production release output confirms
  `transport=Resend from=McRitchie Studio <team@mcritchie.studio>` and Solana
  `mainnet-beta` alignment.
- Turf Monster public production URLs returned `200`:
  `https://app.turfmonster.media/up` and
  `https://app.turfmonster.media/contests/world-cup-week-3-contest`.
- Turf Vault TypeScript tests were rewritten around
  `turf-vault/docs/VERIFICATION_MATRIX.md`.
- Latest Turf Vault local proof: `23 passing` against an isolated validator on
  `127.0.0.1:8898`.

Final closeout checks from this pass:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/install-agent-docs check
bin/register-satellite --list
bin/agent-worktree doctor
```

`bin/install-agent-docs check` passed, and `bin/register-satellite --list`
reported the expected `3000-3099`, `3100-3199`, and reserved `3200-3299`
ranges. The latest `bin/agent-worktree doctor` check reports no worktree
lifecycle issues.

## Residual Risk

These are not blockers to maintenance mode, but they should not be forgotten:

- **Claude adapter decision**: resolved. Claude auth was completed and the
  read-only smoke test passed against generated `AGENTS.md`; no root
  `CLAUDE.md` adapter is needed. App-level `CLAUDE.md` files were removed after
  final review.
- **Broadcast branch**: `mcritchie-studio` branch `feat/broadcasts` has useful
  historical product direction, but it is too stale to merge wholesale.
- **Root stray files**: `/Users/alex/projects/dev-stack-smoothing.md` and
  `/Users/alex/projects/bin/clean-artifacts` were removed after their durable
  content was confirmed in tracked McRitchie Studio docs/scripts.
- **SES production access**: shared email architecture and domain verification
  are ready, and production fallback mail has been proved through the verified
  `mcritchie.studio` Resend domain, but the SES account is still sandboxed.
  Live Heroku `ses:check` on 2026-06-15 also proved the apps do not yet have
  `SES_AWS_ACCESS_KEY_ID` staged, so the task falls back to the S3 IAM user and
  returns SES `HTTP 403`. Stage the SES-scoped API creds first, then confirm AWS
  production access, then run a real SES provider smoke window before Resend
  fallback is removed.
- **Heroku platform drift**: resolved for the active Rails apps on 2026-06-15.
  McRitchie Studio and Turf Monster both run on Heroku-26 with explicit Ruby and
  Node runtime pins.
- **Browserslist freshness**: asset precompile reports the usual
  `caniuse-lite` freshness warning even after `npx update-browserslist-db@latest`.
  This appears tied to the current `tailwindcss-rails 2.7.9` build chain, which
  both apps receive through `studio-engine 0.5.9`. RubyGems currently lists
  `tailwindcss-rails 4.4.0`, so do not treat this as a production blocker or a
  quick patch; handle it during a deliberate Tailwind major-version visual/build
  upgrade window.
- **Turf Vault mainnet feature gates**: local tests cover the default
  localnet/devnet build. Mainnet-only `INIT_AUTHORITY`, canonical USDC, and
  canonical USDT checks still need mainnet build/deploy proof when that window
  opens.
- **Turf Vault lint**: `yarn lint` still reports unrelated pre-existing issues
  in legacy scripts and a hidden salvage worktree. Do not treat that as a
  regression from the verification rewrite.

## Maintenance Loop

At the end of any meaningful feature:

1. Run `git status --short --branch` in the touched repo and any consumer repo.
2. Search docs for changed routes, env vars, ports, providers, versions, and
   workflow names.
3. Update the canonical owning doc, not a new explanatory note.
4. Run `bin/install-agent-docs check` from McRitchie Studio if agent docs changed.
5. If an old file is superseded but not safe to delete, add it to
   `docs/agents/maintenance/delete-later.md`.
6. Hand back a URL, screenshot, test summary, commit, or concrete blocker.

Weekly or after several agent sessions:

1. Run `bin/agent-worktree doctor`.
2. Review the delete-later ledger.
3. Re-check root stray files under `/Users/alex/projects`.
4. Promote durable lessons from local memory or chat into McRitchie Studio docs.

## Next Best Action

The broad audit cleanup is in maintenance mode. Next operational actions are
narrow: stage SES-scoped API credentials for proof tasks, finish AWS SES
production access and provider smoke, schedule the Tailwind major-version
maintenance window, and clean merged worktrees after approval. Keep Resend
configured until SES has a stability window.
