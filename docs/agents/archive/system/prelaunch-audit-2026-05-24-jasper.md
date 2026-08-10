# Pre-Production Audit — On-Chain & Solana Client (Jasper) — 2026-05-24

Independent fresh pass. Not relying on the 2026-05-19 OPSEC audit.

## Executive Summary

I re-derived findings from current code in `/Users/alex/projects/turf-vault` and `/Users/alex/projects/solana-studio`. Two CRITICAL findings block mainnet launch.

**CRITICAL-1** — `migrate_user_account` (`instructions/migrate_user_account.rs:27-155`) accepts the target `wallet` as an UncheckedAccount with no Signer requirement and no binding between the PDA-seed `wallet` arg and the on-chain `user_account.wallet` field. Any 1-of-3 admin (Heroku-resident bot included) can call it. With v0.15 fully rolled out it's a no-op, but any future schema bump re-opens the path — and the v0.13→v0.14 branch zero-fills `username`, so a buggy or hostile admin call can wipe identity. Fix: require wallet Signer or 2-of-3; bind `wallet` to the stored field; refuse unknown legacy sizes.

**CRITICAL-2** — `set_username` (`instructions/set_username.rs`) enforces nothing — no uniqueness, no length, no character set, no rate-limit, no reserved-name protection. A direct program caller bypassing Rails can claim `"alex_mcritchie"`, `"admin"`, or homoglyphs. Anyone treating on-chain username as authoritative is exposed. Fix: at minimum reserved-prefix list; ideally a `UsernameRegistry` PDA + 1/24h rate-limit.

**HIGH-1**: `Contest` accounts lack `seeds = [b"contest", contest_id]` constraint across all entry/settle instructions — a substituted Contest account is accepted as long as discriminator matches.
**HIGH-2**: Token-funded entries do not increment `entry_fees`; with `prizes=0` settle pays $0 — no on-chain backing of operator subsidy.
**MEDIUMs**: `force_close_vault` missing discriminator check (defense-in-depth); `create_user_account` permissionless with caller-chosen username; Borsh integer/string decoders don't bounds-check truncated buffers.
**LOWs**: `mint_entry_token` not pause-gated; `enter_contest_direct_with_token` payer unconstrained; raw-byte `.unwrap()` panic surface; homoglyph usernames.

Off-chain client is well-hardened (OPSEC-017/018/043 all in place, TLS strict, allocation cap, constant-time nonce, prefix host binding). No critical client-side findings. Single-trust-domain Squads keys remain an organizational blocker for Steffon's rollout.

---

## Detailed Findings

### CRITICAL-1 — `migrate_user_account` lets any 1-of-3 admin rewrite any UserAccount, no wallet consent

- **File:** `/Users/alex/projects/turf-vault/programs/turf_vault/src/instructions/migrate_user_account.rs:27-155`
- **Issue:** Line 49 — `pub wallet: UncheckedAccount<'info>` with no Signer requirement, no `has_one`, no constraint binding it to `user_account.wallet`. Line 93 — branching v0.13 vs v0.14 purely by `data.len() >= 113`. Line 98-101 — the v0.13 branch silently sets `username = [0u8; 32]`. The handler reads fields, resizes (line 107), then writes them back. The discriminator check at line 81 is good, but PDA seeds + wallet field are not cross-checked.
- **Why it matters now:** With v0.15 rolled out it's idempotent (line 60 no-op return). **The risk is forward-looking:** any future schema bump re-opens the realloc path. If `Alex Bot` key (single trust domain on Heroku) is compromised, attacker iterates every UserAccount and "migrates" — paths exist where username gets zeroed, and any bug in field-offset arithmetic clobbers `balance` / `total_won`.
- **Attack scenario:** v0.16.0 deploys, bumps `INIT_SPACE`. Every v0.15 account becomes "stale". Attacker with admin key calls `migrate_user_account` per wallet. If a future bump moves a field, the field-by-field read at lines 84-101 deserializes from wrong offsets, writes wrong values, persists. Account-owner has no notification, no consent.
- **Fix:**
  ```rust
  constraint = user_account.try_borrow_data()?.get(8..40)
      .map(|bytes| Pubkey::try_from(bytes).ok() == Some(wallet.key())).unwrap_or(false)
      @ VaultError::Unauthorized
  ```
  Plus require either `wallet: Signer<'info>` OR 2-of-3 (parallel to settle/force_close). Plus `require!(current_len == 81 || current_len == 113, VaultError::InvalidAccountData)` to refuse unknown legacy sizes.

### CRITICAL-2 — `set_username` has zero on-chain validation

- **File:** `/Users/alex/projects/turf-vault/programs/turf_vault/src/instructions/set_username.rs:1-34`
- **Issue:** Only check is `constraint = user_account.wallet == wallet.key()`. The 32-byte `username` is written verbatim. No uniqueness, no length floor, no character set, no reserved-prefix list, no rate-limit.
- **Attack scenarios:**
  - Attacker creates fresh wallet, calls `create_user_account` directly (permissionless — see MEDIUM-2) with `username = "alex_mcritchie"`. Operator impersonation persists on-chain.
  - Bot spams `set_username` calls (~5000 lamports each on devnet) — no on-chain throttle.
  - Two wallets share the same username on-chain; off-chain consumers expecting uniqueness break.
  - Homoglyphs: `"аlex"` (Cyrillic) is on-chain different from `"alex"` (Latin) but renders identically.
- **Fix:**
  - **Minimum (must-do):** reserved-prefix check in handler — `require!(!starts_with(b"admin"), ...)`, plus `"system"`, `"turf"`, `"vault"`, brand names. Plus an `is_printable_ascii` guard rejecting bytes outside `0x20..0x7E` (or a strict UTF-8 normalize).
  - **Better:** add `UsernameRegistry` PDA at `seeds = [b"username", username_bytes]`, init in `set_username`, close prior PDA on overwrite. Solana-native uniqueness, race-free.
  - **Also:** add `last_username_set_at: i64` to `UserAccount` on next layout bump; enforce 1-change-per-24h. Cost: 8 bytes, 1 instruction tweak.
  - **Also (Rails):** treat on-chain username as untrusted input; sanitize before display; never use it for authentication.

### HIGH-1 — Contest account is not PDA-seeds-validated at entry/settle time

- **Files:** `enter_contest.rs:42-46`, `enter_contest_direct.rs:47-52`, `enter_contest_with_token.rs:47-52`, `enter_contest_direct_with_token.rs:42-46`, `settle_contest.rs:45-49`.
- **Issue:** Anchor only verifies discriminator + program ownership on the `Contest` slot. There is no `seeds = [b"contest", contest.contest_id.as_ref()], bump = contest.bump` constraint. So *any* Contest account can be supplied; its stored `contest_id` then drives ContestEntry PDA seeds.
- **Attack on `enter_contest_direct`:** User signs a TX they think targets Contest A ($10 fee). A compromised browser extension or compromised Rails endpoint swaps the `contest` account for Contest B ($1 fee, also Open) before submission. User signs, $1 transferred, entry recorded in B. On-chain is internally consistent but the user got what they didn't intend.
- **Attack on `settle_contest`:** Two cosigners are presented "settle Contest X". Squad TX details show the account list, but a careless cosigner approves a TX where the Contest account is Y. Same auth, wrong target. Defense in depth says program should pin.
- **Fix:** Add to every Contest constraint:
  ```rust
  seeds = [b"contest", contest.contest_id.as_ref()],
  bump = contest.bump,
  ```
  Anchor re-derives the PDA from the account's own stored `contest_id` + `bump` and rejects mismatches.

### HIGH-2 — Token-funded entries don't increment `entry_fees`, settle cap becomes `prizes`

- **Files:** `enter_contest_with_token.rs:101-103`, `enter_contest_direct_with_token.rs:94-96`.
- **Issue:** Both token-funded paths increment `current_entries` but NOT `entry_fees`. `settle_contest.rs:64-68` caps total payouts at `contest.entry_fees + contest.prizes`. So a contest where 100% of entries are token-funded and `prizes == 0` can pay $0 total at settle, even if Rails promised the winner real money.
- **Attack scenario:** Operator (or compromised admin) mints N entry tokens. Users consume them in a contest with `prizes=0`. Settle assigns ranks but `payout` cannot exceed `0+0=0` — the cap will reject any non-zero settlement. Users with "winning" tokens get nothing on-chain. Rails promise to the user is broken with zero on-chain recourse.
- **Fix:** Pick one:
  - (a) Token paths increment `entry_fees` by `contest.entry_fee` (mirrors paid entries) — but then who funds the USDC? Operator must pre-deposit; add a "subsidy" debit at settle.
  - (b) Refuse `mint_entry_token` unless a backing reserve exists (track operator-paid SOL/USDC reserve per contest).
  - (c) Minimum: document loudly in T&Cs that token entries are operator-promised, not on-chain-backed, and that operator subsidy is paid via the prizes pool.

### MEDIUM-1 — `force_close_vault` doesn't verify the discriminator before reading signer bytes

- **File:** `/Users/alex/projects/turf-vault/programs/turf_vault/src/instructions/force_close_vault.rs:43-78`
- **Issue:** Reads bytes 8..104 as three Pubkeys without first checking `data[..8] == VaultState::DISCRIMINATOR`. `migrate_user_account.rs:81` does this correctly — the inconsistency is a defense-in-depth gap.
- **Exploit path:** Not currently exploitable post-init (the PDA address is taken by VaultState). Listed for defense-in-depth parity.
- **Fix:** add `require!(&data[..8] == VaultState::DISCRIMINATOR, VaultError::Unauthorized);` after the length check at line 49. Zero-cost.

### MEDIUM-2 — `create_user_account` is permissionless, caller picks username

- **File:** `/Users/alex/projects/turf-vault/programs/turf_vault/src/instructions/create_user_account.rs:14-54`
- **Issue:** `pub payer: Signer<'info>` with no constraint on who payer is. Anyone can pay rent for anyone's UserAccount and pre-set the username. The wallet owner can later overwrite via `set_username` (CRITICAL-2 caveats apply), but the first-touch window is wide open.
- **Attack:** Front-run a wallet's first signup; set `username = "you_suck"`. User logs in, sees the slur, has to sign a username change. Combine with CRITICAL-2 (no reserved-name list) to set `"admin"` on legitimate user wallets. Also: rent-grief — attacker spams `create_user_account` for thousands of random wallets, paying their own SOL but indirectly congesting the operator's TX-processing pipeline.
- **Fix:** Require either `wallet: Signer<'info>` or a vault signer as payer. The current operator-funded onboarding flow uses Alex Bot as payer for managed wallets, and Phantom signs for their own wallet — both satisfy the tighter constraint.

### MEDIUM-3 — Borsh decoders silently truncate / return nil on short buffers

- **File:** `/Users/alex/projects/solana-studio/lib/solana/borsh.rb:63-91`
- **Issue:** `bytes.byteslice(offset, n)` returns `nil` past EOF or a short slice if running off the end. `decode_u8/u16/u32/u64` then call `.unpack1` — `nil.unpack1` returns `nil`; `"a".byteslice(0,4).unpack1("V")` on a 1-byte string returns garbage. `decode_string` at line 89 does `.to_s` on a possibly-nil slice then returns `offset + length` (the requested offset, not bytes consumed). Downstream decodes are silently misaligned.
- **Attack scenario:** Compromised or buggy RPC returns truncated `getAccountInfo`. Rails reconciler misreads `balance` as a fabricated value. Direct fund-drain not possible (on-chain state unchanged), but operator books diverge from reality.
- **Fix:**
  ```ruby
  def read_exact!(bytes, offset, n, kind)
    slice = bytes.byteslice(offset, n)
    raise "Borsh #{kind}: truncated at offset #{offset}, need #{n}" unless slice && slice.bytesize == n
    slice
  end
  ```
  Apply uniformly to all decode_* functions.

### LOW-1 — `mint_entry_token` not pause-gated

- **File:** `/Users/alex/projects/turf-vault/programs/turf_vault/src/instructions/mint_entry_token.rs:24-25`
- **Rationale (comment):** "operators must be able to fulfill Stripe purchases that completed before the pause". Operationally sound, but if the pause reason IS "admin key compromised", attacker mints unlimited tokens during the pause, redeems after unpause.
- **Fix:** Add a separate `mint_paused` flag, independently flippable 2-of-3. Or gate `mint_entry_token` on pause too and accept the operational tradeoff.

### LOW-2 — `enter_contest_direct_with_token` payer is unconstrained

- **File:** `/Users/alex/projects/turf-vault/programs/turf_vault/src/instructions/enter_contest_direct_with_token.rs:21-22, 35-39`
- **Issue:** Unlike `enter_contest_direct.rs:40-45` (OPSEC-024 gates payer to vault signer), this path leaves payer open. Bounded by user-signer-required + valid token, so not directly exploitable, but inconsistent with the sibling.
- **Fix:** Optional. For consistency, add the vault-signer constraint on payer.

### LOW-3 — `.unwrap()` on raw-byte slice conversion in `migrate_user_account`

- **File:** `/Users/alex/projects/turf-vault/programs/turf_vault/src/instructions/migrate_user_account.rs:86-90`
- **Issue:** `u64::from_le_bytes(data[40..48].try_into().unwrap())` panics on slice-length mismatch. Currently safe because of the `data.len() >= 81` guard at line 75, but a future refactor that loosens the bound converts runtime check into a panic-abort.
- **Fix:** propagate with `?` instead of `.unwrap()`.

### LOW-4 — Username homoglyph attacks

- **Files:** `set_username.rs:28-34`, `create_user_account.rs:44`
- **Issue:** Raw `[u8; 32]` stored, no normalization. Cyrillic `а` displays identically to Latin `a`.
- **Fix:** Off-chain Rails normalize + reject confusables; on-chain optionally reject bytes outside `0x20-0x7E`.

### LOW-5 — Borsh integer decoders (sibling of MEDIUM-3)

- **File:** `/Users/alex/projects/solana-studio/lib/solana/borsh.rb:63-81`
- **Same root cause as MEDIUM-3** — separated only because integer fields are higher-frequency in account decodes than strings.

### LOW-6 — AuthVerifier prefix-match host binding

- **File:** `/Users/alex/projects/solana-studio/lib/solana/auth_verifier.rb:85-87`
- **Issue:** `message.start_with?("#{expected_host} ")` is currently strict-enough (trailing space delimiter), but a future message format that prepends `"https://"` or appends `":443"` would break the check open or silently fail-closed.
- **Fix:** consider exact-match on first whitespace-delimited token.

## Checked, fine (no findings)

- **Withdraw daily cap** (`withdraw.rs:62-122`): rolling 24h, correctly resets via `saturating_sub`; first-call init when `daily_window_start=0` works because `now - 0 >= 86_400`.
- **Settle dedup + reentrancy** (`settle_contest.rs:75-80, 127`): `seen` Vec + `entry.status == Active` closes double-payout vectors.
- **Total-payout cap** (`settle_contest.rs:64-68`): correct.
- **OPSEC-025** (sum overflow in `create_contest.rs:80-83`): correctly fixed with `try_fold + checked_add`.
- **OPSEC-004** wallet co-sign on `enter_contest_with_token.rs:31`: correct Signer requirement.
- **OPSEC-027** continuity in `update_signers.rs:43-48`: correct.
- **OPSEC-026** already-migrated guard in `force_close_vault.rs:55-61`: correct.
- **OPSEC-017/043** in `solana-studio/lib/solana/transaction.rb:88-91, 116-119, 130-135`: correct.
- **TLS strict** in `solana-studio/lib/solana/client.rb:144-180`: explicit `VERIFY_PEER` + TLS 1.2 min, http rejected unless localhost.
- **Borsh allocation cap** (`borsh.rb:8`): 10MB on length-prefixed decodes.
- **AuthVerifier constant-time + nonce-deletion contract** (`auth_verifier.rb:11-23, 100-102`).
- **PDA seed prefixes** all distinct across `VaultState`/`UserAccount`/`Contest`/`ContestEntry`/`EntryTokenAccount`/`Season` — no cross-entity collision risk.
- **Vault pause coverage** on all 6 user-facing funds ops; settle/mint/migrate/set_username/create deliberately exempt and documented.
- **Anchor discriminator wire format** in `transaction.rb:19-21`: `SHA256("global:<name>")[0,8]` matches Anchor.
- **Settle `remaining_accounts` PDA verification** (`settle_contest.rs:92-108`): recomputes both PDAs from `wallet` + `entry_num`, rejects substitution.

## Squads / organizational

- Single trust domain (1Password) for Alex Bot + Mason keys remains the largest residual risk for a mainnet launch. Program-level mitigations are in place (OPSEC-026, OPSEC-027, pause), but if 1Password is compromised the attacker gets program-upgrade authority AND 2-of-3 multisig — game over. **Recommend before mainnet:** move Mason's Squads member key to Mason's hardware wallet only; consider Squads time-locks on upgrades. This is Steffon's rollout-protocol territory.

## IDL pinning

- On-chain program does not enforce IDL hash; that's strictly an off-chain operator-discipline check via `EXPECTED_IDL_HASH` in turf-monster. The wire-format discriminator naming is `SHA256("global:<name>")[0..7]` which fails loudly on rename. As long as the post-Squads-deploy re-pin-from-BUILT-IDL protocol is followed (OPSEC-014), this is fine.

## Prioritized launch gate

**Block launch (must fix):**
1. Lock down `migrate_user_account` (CRITICAL-1)
2. Add minimal on-chain validation to `set_username` — reserved-prefix list + rate-limit (CRITICAL-2)

**Strongly recommend before launch:**
3. PDA-seed-pin every Contest constraint (HIGH-1)
4. Decide policy on token-entry backing (HIGH-2)
5. Tighten `create_user_account` permissionlessness (MEDIUM-2)
6. Borsh decoder bounds checks (MEDIUM-3)

**Post-launch acceptable:**
7. Discriminator check in `force_close_vault` (MEDIUM-1)
8. Mint pause separate flag (LOW-1)
9. Username normalization (LOW-4)

**Organizational (Steffon):**
10. Move Mason's Squads key out of shared 1Password before mainnet.
