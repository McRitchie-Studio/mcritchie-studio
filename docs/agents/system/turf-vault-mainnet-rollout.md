# turf-vault Mainnet Rollout — 3-Phase Checklist

> **When to read this:** You're ready to ship `turf-vault` to mainnet. Don't skip phases. Each gate exists because the previous one's success isn't yet proven.

> **RECONCILED 2026-09-16 — every box below was re-derived, not ticked from
> memory.** Mainnet has run program `DaFv83yo…` since 2026-06-02, so this file is
> now a plan checked against what happened. Each box carries one mark and its
> evidence:
>
> - **DONE** — measured true; the box is checked.
> - **NOT MET** — measured false; the box stays open.
> - **UNSETTLED** — no read available here could decide it; the box stays open.
>
> Chain reads were taken at `finalized`. App reads came from `turf-monster`'s
> `origin/main`, the `turf-monster-mainnet` Heroku config, and the repo's GitHub
> Actions history. A mark is a dated reading, so re-derive before you rely on one.
>
> **Two multisigs appear below, and they carry different numbers.** Squads holds
> the program's upgrade authority: both live Squads read 3-of-5 since 2026-09-15.
> `VaultState` is the program's own signer set, still 2-of-3 on the deployed
> v0.25. Every threshold in this file names which one it means.
>
> **No phase advance is recorded.** The decision log at the bottom is empty. The
> chain shows 8 contests, 36 entries and 42 user accounts on mainnet between
> 2026-06-02 and 2026-09-16. Which phase that use belongs to was never written
> down, and the chain cannot say.

## Pre-flight (do all of these BEFORE Phase A)

- [ ] External audit completed (see [`turf-vault-audit-rfp.md`](./turf-vault-audit-rfp.md)) — **UNSETTLED (2026-09-16).**
  No external audit is on file in either repo. The one audit artifact is an
  internal adversarial review, `turf-vault/docs/SECURITY_AUDIT_2026_05_31.md`, and
  the RFP linked here is scoped to v0.8.0 on devnet. An engagement recorded
  nowhere in the repos cannot be ruled out from here.
- [ ] All Critical + High findings fixed and re-audited — **UNSETTLED (2026-09-16).**
  It depends on the external audit above. The internal 2026-05-31 review's own
  banner records several of its highs as remediated in source; no re-audit is on
  file.
- [x] Squads multisig upgrade authority transferred and rehearsed (see [`squads-upgrade-authority-migration.md`](./squads-upgrade-authority-migration.md)) — **DONE (2026-09-16).**
  - *Transferred:* a `SetAuthority` on the mainnet program `DaFv83yo…`'s
    ProgramData moved upgrade authority from the deploy key `8K81…` to the Squads
    vault `Bk9sS7ii…` at 2026-06-02T19:14:10Z (slot `423870782`), 17 seconds after
    the first deploy. That vault is derived as index 0 of multisig `4H3fP3ot…`, and it is
    still the program's authority.
  - *Rehearsed:* two real upgrades have executed through that Squad — its
    transactions #1 (2026-06-08) and #2 (2026-06-11, the last deploy).
  - *Caveat:* both ran under the June membership, when that Squad was 2-of-3.
    None has run since it became 3-of-5 on 2026-09-15. The agent holds two of the
    five mainnet seats, so the next upgrade stops for Alex by design.
- [x] IDL hash pinning live in production turf-monster (ecosystem audit Tier 3 #22). `EXPECTED_IDL_HASH` set in Heroku. — **DONE (2026-09-16).**
  `EXPECTED_IDL_HASH` on `turf-monster-mainnet` equals the sha256 of
  `turf-monster/config/turf_vault.mainnet.idl.json` (`b9b52263…`). Neither
  `BYPASS_IDL_CHECK` nor `SKIP_IDL_VERIFICATION` is set, and
  `Solana::Config.verify_idl!` raises at boot in production on a mismatch. The
  app's `SOLANA_PROGRAM_ID` is `DaFv83yo…`.
- [ ] Devnet integration suite green for at least 7 consecutive nights (ecosystem audit Tier 3 #21 — nightly Playwright @devnet job) — **NOT MET (2026-09-16).**
  `turf-monster`'s Devnet Nightly workflow has never passed. Of its 124 runs from
  2026-05-18 to 2026-09-16, 123 were skipped — the job is gated on the
  `DEVNET_NIGHTLY_ENABLED` repository variable — and one failed (2026-08-20).
- [ ] Sentry wired up + receiving events (ecosystem audit Tier 2 #15) — **UNSETTLED (2026-09-16).**
  Wired, yes: `sentry-ruby` and `sentry-rails` are in `turf-monster`'s Gemfile,
  and `SENTRY_DSN` is set on `turf-monster-mainnet`. Whether events arrive needs a
  read of Sentry itself, which was not available here.
- [ ] Reconciler cron running + alert webhook validated (ecosystem audit Tier 2 #17) — **NOT MET, by design (2026-09-16).**
  The scheduled `solana_reconcile` cron was removed on 2026-05-19 (OPSEC-040,
  recorded in `turf-monster/config/schedule.yml`), and reconciliation is now ad
  hoc (`bin/rails solana:reconcile`). The `pending_deposit_reconciler` and
  `pending_contest_reconciler` crons that do run repair stranded rows, not balance
  discrepancies. So the Reconciler gates below have no scheduled job to read.
- [ ] Secrets-rotation runbook reviewed; all secrets rotated within last 90 days (ecosystem audit Tier 2 #18) — **NOT MET (2026-09-16).**
  [`secrets-rotation.md`](./secrets-rotation.md) records
  `MANAGED_WALLET_ENCRYPTION_KEY` as never rotated. Whether the runbook was
  reviewed is not recorded.
- [ ] Bug bounty live on Immunefi (or scheduled to launch with Phase A) — **UNSETTLED (2026-09-16).**
  Neither Immunefi nor a bug bounty is mentioned in `turf-vault` or
  `turf-monster`. A program run outside the repos cannot be ruled out from here.
- [ ] Communications plan: who announces, on what channels, what to say if things break — **UNSETTLED (2026-09-16).**
  This file carries a worst-case template (below). No plan naming who announces,
  or on which channels, was found.

## Phase A — Mainnet smoke (1-2 weeks)

**Goal:** prove the deployed mainnet program works in production conditions with zero blast radius if anything is wrong.

**Constraints:**
- Internal users only (the 3 `VaultState` signers, no public access)
- Single test contest with **$5-10 total at risk** (small entry fees, small prize pool)
- Mainnet account funding from a dedicated low-balance wallet — not from significant treasury

**Steps:**
1. Deploy `turf-vault` to mainnet (audit-signed-off version) with single key as initial upgrade authority.
   *Ran 2026-06-02:* `DaFv83yo…` was deployed at 19:13:53Z by the single key
   `8K81…`. A first program, `mnzow…`, was deployed that morning and abandoned
   after the Alex Bot leak. It stayed open until 2026-09-16, when Alex
   closed it through its Squad `9dCLM…` and removed the leaked `F6f8…` from that
   Squad (`squads-upgrade-authority-migration.md`, **How it resolved**).
2. Run the full Phase 4 Squads upgrade-authority migration (see runbook).
   *Ran 2026-06-02:* authority reached the Squads vault at 19:14:10Z (pre-flight
   item 3).
3. Initialize VaultState with the 3 mainnet multisig signers + threshold 2.
   *Ran 2026-06-02:* `initialize` at 19:23:59Z wrote signers `8K81…` / `7ZDJ…` /
   `CytJ…` at threshold 2. That is the `VaultState` 2-of-3, unchanged since, and a
   different set from the Squads membership.
4. Create a USDC ATA for the vault. *Done:* the vault PDA owns USDC token
   accounts on mainnet (read 2026-09-16).
5. Each of the 3 signers deposits a small amount (e.g. $5 each) via the Rails app pointed at mainnet.
6. Create an internal contest with entry fee $1, max 3 entries.
7. Each signer enters one matchup set.
8. Simulate games or wait for real game results.
9. Settle contest (admin signs as `admin`, and a second `VaultState` signer
   cosigns — settlement is the `VaultState` 2-of-3 on the deployed v0.25; Squads
   takes no part in it).
10. Verify each signer receives correct payout in their wallet.
11. Reconciler runs + reports no discrepancies.
12. Withdraw all remaining balances. Verify zero balance in vault PDA.

Steps 5–12 describe an internal smoke run. On chain it cannot be told apart from
the use that followed, so it is read through the gates below.

**Phase A gates → go to Phase B when ALL of these are true:**
- [ ] 5+ successful end-to-end test contests (create → enter → settle → withdraw) — **NOT MET (2026-09-16).**
  Only 4 `settle_contest` calls have ever succeeded on mainnet (2026-06-03 to
  2026-09-07), counted from all 164 transactions on `DaFv83yo…` with none
  unreadable. Across the same span: 8 `create_contest`, 36 entries, 2
  `cancel_contest` and 1 `close_contest`.
- [ ] Zero Reconciler discrepancies for 7 consecutive days — **UNSETTLED (2026-09-16).**
  No scheduled reconciler runs, so there is nothing to count (pre-flight item 7).
- [ ] No Sentry-paged exceptions related to Solana code in 7 days — **UNSETTLED (2026-09-16).**
  No Sentry read was available.
- [ ] Multisig cosign flow worked smoothly each time (no manual recovery needed) — **UNSETTLED (2026-09-16).**
  This is the `VaultState` cosign. Ten transactions on `DaFv83yo…` failed, and
  their logs cannot say whether a cosign caused any of them.
- [ ] At least one no-op upgrade proposal rehearsed through Squads on mainnet — **NOT MET as written (2026-09-16).**
  No no-op proposal exists. The mainnet Squad's four transactions are two real
  upgrades (#1, #2) and two membership changes (#3, #4, both 2026-09-15). The flow
  this gate exists to prove was exercised by those two upgrades — pre-flight
  item 3.

## Phase B — Real users, capped (4 weeks)

**Goal:** prove the system handles real money + real users under realistic load, but with the blast radius capped so a worst-case bug is recoverable.

**Constraints:**
- Public-facing, but with hard caps
- **Per-contest TVL cap: $500-1000** (sum of entry fees + prizes)
- **Daily mint cap: $5000 total deposits across all users**
- Daily withdraw cap: $5000 (forces partial recovery in case of bug)
- Show "Beta" badge on the UI

**Implementation needs:**
- Add daily-totals tracking to Rails — `Daily::Totals.deposits_today`, `Daily::Totals.contest_tvl(id)`
- Block deposit endpoint if daily total exceeds cap
- Block contest creation if proposed TVL exceeds per-contest cap
- Surface caps in UI ("$X of $5000 daily limit remaining")
- Add admin override for emergencies (cosigned by two `VaultState` signers on the deployed v0.25)

*Read 2026-09-16:* none of these is built — `turf-monster`'s `origin/main` has no
`Daily::Totals`.

**Communications:**
- Public launch post (X, blog, anywhere @turfmonstershow has reach)
- "Beta" badge prominently displayed on the UI + every contest
- Discord/Slack support channel for users who hit caps or have questions

**Phase B gates → go to Phase C when ALL of these are true:**
- [ ] 50+ contest settlements completed — **NOT MET (2026-09-16).**
  Four, in total, on mainnet (Phase A's first gate).
- [ ] Zero Reconciler divergence > $1 across the whole period — **UNSETTLED (2026-09-16).**
  No scheduled reconciler (pre-flight item 7).
- [ ] Zero unrecovered Sentry pages — **UNSETTLED (2026-09-16).** No Sentry read was available.
- [ ] No multisig cosign failures — **UNSETTLED (2026-09-16).**
  The `VaultState` cosign; see the matching Phase A gate.
- [ ] No need to use Squads override or `force_close_vault` — **UNSETTLED (2026-09-16).**
  Clean to date: `force_close_vault` has never been called on mainnet, and the
  Squad's only transactions are two upgrades and two membership changes. But the
  gate is measured across a Phase B window that was never declared.
- [ ] User feedback channel has no unresolved bug reports — **UNSETTLED (2026-09-16).**
  No feedback channel was read.
- [ ] (Optional) follow-up audit pass on any code added during Phase B — **UNSETTLED (2026-09-16).**
  No Phase B was declared, and no audit pass is on file.

## Phase C — Uncapped (ongoing)

**Goal:** normal operation. Caps lifted; growth driven by demand.

**Steps:**
1. Lift per-contest TVL cap and daily totals.
2. Remove "Beta" badge.
3. Continue Reconciler cron, Sentry monitoring, weekly multisig health checks.
4. Re-run external audit annually OR when significant new code lands (`update_signers` of new signers, new instruction added, etc.).

**Ongoing operational rituals:**
- **Weekly**: review Reconciler discrepancy reports (if any), confirm Sentry error rate is flat/down
- **Monthly**: rehearse a no-op upgrade through Squads (so the muscle memory + signer availability stays current)
- **Quarterly**: secrets rotation per [secrets-rotation runbook](./secrets-rotation.md)
- **Annually**: re-audit (especially if new instructions added)

## If something breaks in Phase A or B

**Symptom → first action**:

| Symptom | First action |
|---------|--------------|
| Reconciler discrepancy alert | Read ErrorLog + run `bin/rails solana:reconcile_user ADDRESS=<wallet>` to see specifics. Don't drain vault. |
| User reports lost funds | Check on-chain via `solana account <user_pda>` — if balance is correct on-chain, it's a Rails/UI bug, not lost funds. |
| Sentry: signature verification failure cluster | Check IDL hash. May indicate program drift. |
| Squads cosign not landing | Check signer availability. Use Squads UI to inspect the proposal state. |
| Mass settlement failure | DON'T retry blindly. Check what was actually written on-chain via `anchor view`. Reconciler shows truth. |
| Suspected compromise of any signer key | Immediate `update_signers` cosigned by the two uncompromised `VaultState` signers — two signatures on the deployed v0.25; v0.26 raises this action to three (`turf-vault/docs/SIGNER_ROTATION.md`). Then evict the key from every other authority it holds: Squads membership is a separate transaction, and a pre-rotation deployment can still seat the key (`turf-vault/docs/CURRENT_DEPLOYMENT.md`). |

**If you need to halt operations** (worst case):
- Pause Rails-side contest entry endpoint (set a `Contests::EntryOpen = false` flag, surface in UI).
- This doesn't pause on-chain — already-entered contests still settle normally.
- Don't `force_close_vault` unless you can prove user funds are at risk; that's a one-way operation.

## Communication template (worst case)

If a critical bug surfaces and you need to communicate publicly:

```
Hi everyone — we discovered <brief description of issue> in turf-monster
at <time>.

What happened: <facts only; no speculation>
What we're doing: <specific actions>
Funds status: <"all funds are safe and accounted for" OR "X users affected, we're contacting directly">
Timeline: <expected resolution window>

We'll post updates every <N> hours until resolved.

— Alex
```

Be specific about funds status — vague language amplifies panic.

## Post-launch: what gets easier vs harder

**Easier**:
- New contest creation (everything's hot, no cold-start)
- Settlement (well-rehearsed cosign flow)
- Adding satellites (engine + scaffolder are in place per audit Tier 2 #11 + Tier 3 #24)

**Harder**:
- Schema migrations (multisig adds friction)
- Signer rotation if someone leaves the team (a Squads config transaction approved at that multisig's threshold — 3 on both live Squads since 2026-09-15 — and a separate `update_signers` cosigned by current `VaultState` signers, two signatures on the deployed v0.25)
- Reputational recovery from any user-facing bug (slow, painful — invest disproportionately in monitoring)

## Decision log

When you decide to advance from one phase to the next, record:
- Date of decision
- Who decided
- Which gates were specifically met
- Any waived gates and why

Keep this in a simple table at the end of this file or a separate runlog. The record matters if a Phase C bug surfaces and you need to trace what was tested vs assumed.

*Checked 2026-09-16:* no table has been added here, so no phase decision is on
record.
