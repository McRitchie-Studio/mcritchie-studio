# turf-vault External Audit — RFP, Firm Comparison, Outreach Draft

> **When to read this:** You're ready to start the conversation with a Solana audit firm. This doc bundles the scope summary you'd send, a comparison of the four firms worth contacting, and a draft email template.

## TL;DR

`turf-vault` is a focused Anchor program (12 instructions, 4 account structs, 2-of-3 multisig). External audit budget realistic range: **$20k–$60k**, lead time **4–8 weeks**. Recommended order of outreach: **Neodyme → Halborn → OtterSec → Zellic**, picking whichever delivers the earliest realistic start date with quoted scope coverage.

## Scope Summary (paste into RFP form)

**Project**: turf-vault — Anchor escrow program for sports-pick'em contests on Solana.

**Repo**: https://github.com/McRitchie-Studio/turf-vault

**Current status**: Deployed to devnet at `7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J`. Pre-mainnet. v0.8.0.

**Stack**:
- Anchor 0.32.1
- Rust 1.89.0
- Solana / Agave 3.x
- ts-mocha tests (29 cases against local validator)

**Code size**: ~12 instruction handlers in `programs/turf-vault/src/instructions/`, 4 account structs in `state.rs`, 13 error codes, single program — no cross-program invocations beyond SPL Token CPIs (deposit, withdraw, transfer).

**Sensitive surface**:
- 2-of-3 multisig (Squads-style inline) gates settlement, force-close, and signer rotation. Multisig logic is in `state.rs::validate_multisig`.
- `settle_contest` uses Anchor's `remaining_accounts` pattern to bypass account-resolution limits — manual PDA verification + `try_deserialize`/`try_serialize` round-trips.
- `force_close_vault` reads signers from raw account bytes (avoids deserialization of old schema). Migration-only.
- `enter_contest_direct` lets users sign their own USDC ATA transfer (Phantom wallets); `enter_contest` lets admin debit a PDA balance (managed wallets).
- All arithmetic uses `checked_add` / `checked_sub`.

**Specific concerns to focus on**:
1. **Multisig completeness**: any path to settle/withdraw/migrate without 2-of-3 cosign?
2. **`remaining_accounts` PDA verification**: is the manual verification in `settle_contest` complete? Spoofed `user_account` or `contest_entry` PDAs?
3. **Re-entrancy / CPI ordering**: SPL Token CPIs during deposit/withdraw — any state mutation after CPI that could be exploited?
4. **`force_close_vault` raw-byte parsing**: safe against malformed-data crash on mainnet?
5. **Seed economy (`seeds += 65` per entry)**: integer overflow paths? Off-by-one in level derivation (Rails reads, levels = seeds/100+1)?
6. **`enter_contest_direct` token-account substitution**: ensure user can't pass a different ATA than the one they're signing for.

**Token amounts**: u64 with 6 decimals (1 USDC = 1_000_000). Max realistic balance under-cap ≈ $1M = 10^12 lamports — well below u64 ceiling but checked_add still required for sum-of-payouts validation.

**Deployment authority**: currently a single keypair (`~/.config/solana/id.json`). **This is the single biggest pre-audit risk** — see audit Tier 3 #20 (Squads upgrade-authority migration). Recommend doing that migration BEFORE the audit starts so audit firms can verify the multisig upgrade path.

**Expected deliverables from auditor**:
- PDF report with findings categorized by severity (Critical / High / Medium / Low / Informational)
- Each finding: location, description, impact, recommended remediation
- Re-audit pass after fixes (typically included)
- Public report (optional — we may publish to build trust with creators/users)

**Out of scope**:
- Off-chain Rails app (turf-monster)
- IDL parsing on the Rails side (we own that risk via Tier 3 #22 IDL pinning)
- Web frontend (Phantom integration)

## Firm Comparison

Updated 2026-05-17. Cross-check pricing directly with each firm — these are rough ranges based on public engagements + community knowledge.

### Neodyme
- **Site**: https://neodyme.io
- **Solana-native**: yes — top of the Solana-specific list, particularly known for finding subtle Anchor bugs
- **Lead time**: ~4-6 weeks
- **Budget range**: $30-50k for a program this size
- **Style**: Deep, methodical. Strong on cryptographic correctness + economic exploits.
- **Past work**: Many Solana DeFi protocols; Mango Markets post-hack work.
- **Best fit if**: you want the most thorough Solana-specific review even if more expensive.

### Halborn
- **Site**: https://halborn.com
- **Solana-native**: yes (also cross-chain — EVM, etc.)
- **Lead time**: ~6-8 weeks
- **Budget range**: $25-60k
- **Style**: Process-driven, formal reports. Strong brand for "yes we've been audited" trust signaling.
- **Past work**: Solana ecosystem (Step, Marinade), broader DeFi.
- **Best fit if**: you want a recognizable firm name on the public report.

### OtterSec
- **Site**: https://osec.io
- **Solana-native**: yes — built on Solana from day one
- **Lead time**: ~4-6 weeks
- **Budget range**: $20-40k for small programs
- **Style**: Pragmatic, fast turnaround. Strong with Anchor specifically.
- **Past work**: Many Solana protocols including Tensor, MarginFi, Drift.
- **Best fit if**: you want quick turnaround at reasonable cost, with deep Solana familiarity.

### Zellic
- **Site**: https://zellic.io
- **Solana-native**: yes (also EVM)
- **Lead time**: ~6-8 weeks
- **Budget range**: $30-50k
- **Style**: Heavy on cryptography + formal methods. Strong with custom signature schemes / multisig.
- **Past work**: Some Solana DeFi + several L1/L2 audits.
- **Best fit if**: you want extra rigor on the multisig design specifically.

## Outreach Email Template

Send the same email to 2-3 firms simultaneously to compare quotes + start dates.

```
Subject: Anchor program audit — turf-vault (~12 instructions, 2-of-3 multisig)

Hi <Firm name> team,

I'm looking to schedule an external audit for turf-vault, a Solana
escrow program currently deployed on devnet. Targeting mainnet
launch in the next 1-2 quarters; the audit is a hard prerequisite.

Quick scope:
  - Anchor 0.32.1, ~12 instructions, 4 account structs
  - 2-of-3 multisig gates settlement, force-close, signer rotation
  - SPL Token CPIs for deposit/withdraw/transfer (USDC + USDT)
  - Two contest-entry modes (managed PDA + Phantom direct)
  - Full repo: https://github.com/McRitchie-Studio/turf-vault
  - Detailed scope summary attached / link below

We're particularly interested in your review of:
  - Multisig completeness (any bypass paths?)
  - remaining_accounts PDA verification in settle_contest
  - re-entrancy / CPI ordering in deposit/withdraw
  - force_close_vault raw-byte parsing safety

I'd appreciate:
  1. A ballpark fee + lead-time estimate
  2. Earliest realistic start date
  3. Whether re-audit after fixes is included
  4. Sample report (if shareable) so we can see your output format

Happy to schedule a 30-min intro call this week or next.

Thanks,
Alex McRitchie
alex@mcritchie.studio
```

## After the Quote: Decision Criteria

When comparing responses:
1. **Start date** — sooner > later; mainnet is gated on this.
2. **Coverage of named concerns** — does their quote explicitly address multisig + remaining_accounts + force_close? Vague quotes = vague audits.
3. **Re-audit included** — should be yes; if not, factor extra ~30% into total cost.
4. **Public report option** — important for trust signaling post-launch.
5. **Past Anchor-specific work** — ask for 2-3 references they've audited.

Avoid firms that quote $5-10k for "a quick review" — that's a price signal that they're not doing the depth this needs.

## Post-Audit Steps

After the report lands:
1. Triage findings by severity (Critical/High immediately; Medium/Low schedule).
2. Fix in turf-vault repo, push, re-run all tests.
3. Re-audit pass.
4. Final public report (if going that route).
5. Then proceed to ecosystem-audit Tier 3 #20 (Squads upgrade authority) if not already done.
6. Then Tier 3 #23 (3-phase mainnet rollout).
