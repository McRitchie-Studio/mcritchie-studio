# Multi-Auth Identity Design — Eliminating the Merge Hijack Primitive

**Status (2026-05-23):** ✅ **SHIPPED to turf-monster prod (v80).** OPSEC-005 is checked off in `opsec-audit-pre-prod-2026-05-19.md`. `merge_users!` was replaced by the Identity-per-User design described below: each auth method (`email+password`, `google`, `phantom`) proves independently, collisions refuse instead of session-swapping, and OAuth requires `email_verified == true`. Backfill landed cleanly. **Still pending:** porting the design to mcritchie-studio (lower priority since the hub holds no money).

**Audit ref:** OPSEC-005 in `opsec-audit-pre-prod-2026-05-19.md`. Mainnet-blocking.
**Goal:** Let a single super-user safely hold password + Google + Phantom — and any future auth method — without `merge_users!` becoming an account-takeover surface.
**Scope:** turf-monster (where the user actually has money). The same design should land in mcritchie-studio later for consistency.

---

## The shape of the problem

A "user" today is `User` + a tangle of auth fields directly on the row:
- `email + password_digest` (bcrypt)
- `provider + uid` (one OAuth provider)
- `web2_solana_address` (managed, server holds the encrypted key)
- `web3_solana_address` (self-custody Phantom)

Whenever a sign-in path discovers that *another* user already holds the credential being presented, the controller calls `merge_users!(survivor: current_user, absorbed: existing)`. Inside `merge_users!`, the survivor is forced to be the lower ID, then `set_app_session(survivor)` switches the session.

This creates three problems we want to make impossible by design:

1. **Session-swap on collision** — if attacker A logs in, then a collision is triggered (link_solana, OAuth callback, even the `from_omniauth` email path), attacker A's session becomes the older account's session. Bad.
2. **Silent absorption of provider links** — `from_omniauth` finds a password user by email and silently links Google to them without confirming the user is the same human.
3. **Irreversible** — `absorbed.destroy!` runs. If the merge was a mistake, the absorbed account is gone.

The aim of this design: **one User per human, multiple Identities per User**. Each identity is proven independently. Merging two Users requires explicit confirmation from *both* sides.

---

## Proposed model

### New: `auth_identities` table

```ruby
create_table :auth_identities do |t|
  t.references :user, null: false, foreign_key: true, index: true
  t.string :kind, null: false                # 'password' | 'google' | 'phantom' | future
  t.string :external_id, null: false         # email (password/google) or wallet pubkey (phantom)
  t.jsonb :metadata, null: false, default: {} # provider name, uid, verified_at, last_used_at, etc.
  t.datetime :verified_at                    # when was last proven (signature / OAuth completion)
  t.datetime :revoked_at                     # nil = active
  t.timestamps
end
add_index :auth_identities, [:kind, :external_id], unique: true, where: "revoked_at IS NULL"
add_index :auth_identities, [:user_id, :kind]
```

Key constraint: the partial unique index `(kind, external_id) WHERE revoked_at IS NULL` ensures one active identity per kind+id at any time. Two Users cannot both hold the same active wallet/email/Google account.

### Migration of existing data

```ruby
# Idempotent backfill — one row per identity that exists today
User.find_each do |user|
  AuthIdentity.create_with(verified_at: user.created_at).find_or_create_by!(
    kind: 'password', external_id: user.email
  ) if user.email.present? && user.password_digest.present?

  AuthIdentity.create_with(verified_at: user.created_at, metadata: { provider: user.provider, uid: user.uid })
    .find_or_create_by!(kind: 'google', external_id: user.email) if user.provider == 'google_oauth2'

  AuthIdentity.create_with(verified_at: user.created_at)
    .find_or_create_by!(kind: 'phantom', external_id: user.web3_solana_address) if user.web3_solana_address.present?

  # web2_solana_address is a managed wallet — not an identity, an asset the user holds
end
```

The legacy fields stay on `users` for now as denormalized read-side caches. Writes go through `AuthIdentity`. Eventually drop the columns.

### Sign-in resolution

```ruby
# Sessions / OAuth callbacks / wallet-auth verify all resolve via:
identity = AuthIdentity.active.find_by(kind:, external_id:)
return identity.user if identity   # always; never auto-create when logged in
```

`User.from_omniauth` becomes `AuthIdentity.find_by(kind: 'google', external_id: auth.info.email)` and then a *separate* explicit "Add Google to your account" flow if no identity exists yet.

---

## How each sign-in flow changes

### Adding a new auth method to a logged-in account

Single canonical flow:

1. User is logged in via existing identity (any).
2. User clicks "Add Google" / "Connect Wallet" / "Set Password".
3. We start a verification flow appropriate to the kind (OAuth round-trip, signed message, password confirm).
4. On success, we look up `AuthIdentity.active.find_by(kind:, external_id:)`:
   - **No existing identity** → create one bound to `current_user`. Done.
   - **Identity exists and belongs to `current_user`** → no-op (already linked).
   - **Identity exists and belongs to a different user** → **refuse with explicit error**. Show the user a "Merge accounts" flow (see below). Never auto-merge.

This eliminates the silent-link primitive entirely. The current `OmniauthCallbacksController#create` would no longer call `merge_users!`; it would render an error and a "Looks like you already have an account — sign in with that instead, or request a merge" CTA.

### Sign-in from scratch

1. User presents a credential (password, Google, Phantom signature).
2. Verify the credential.
3. `AuthIdentity.active.find_by(kind:, external_id:)`:
   - **Found** → log in as `identity.user`. Done.
   - **Not found** → create a new User + identity. (Same as today's signup.)

Note the absence of the `from_omniauth` email-fallback path. **Google's email is no longer a join key for finding a password user.** This closes OPSEC-005 scenario C entirely.

### Explicit account merge (the only path that destroys an account)

Required because legitimate users will occasionally double-create accounts. But it must require proof from BOTH sides.

1. While logged in to Account A, user clicks "I have another account — merge it".
2. We email a one-time merge token to A's verified email AND require sign-in to Account B from a separate session (different browser/incognito).
3. After B logs in and clicks the link, a server-side merge proposal is created: `MergeProposal{from_user_id: B, into_user_id: A, expires_at: 24h, confirmed_by_a: bool, confirmed_by_b: bool}`.
4. Both A and B must explicitly click "Confirm merge" while logged in to their respective accounts. Server requires both flags + freshness check.
5. Merge executes: move identities + entries + tokens from B into A. Mark B `merged_into: A.id, deactivated_at: now`. **Do not `destroy!` B** — soft-delete so the merge is auditable + reversible for ~30 days.

Compared to current `merge_users!`, this:
- never fires implicitly from a sign-in collision
- requires consent + proof from both sides
- preserves audit trail
- has a reversal window

---

## What the user experiences

A super-user (password + Google + Phantom + a managed wallet) sees:

- One User record. One session.
- "Identities" section on `/account` showing each linked method, when last verified, "remove" buttons (with confirmation + step-up auth).
- "Sign in with X" works the same as today from any of their methods.
- If they ever try to add an identity that's claimed by another account, they see: "This Google account is already linked to a different Turf Monster account. [Sign in there instead] or [Request to merge accounts]."

No path through the UI can silently swap their session into a different user.

---

## Security properties (what this gives us)

| Property | How it's enforced |
|---|---|
| One active claim per credential | DB partial unique index `(kind, external_id) WHERE revoked_at IS NULL` |
| No session swap on collision | Sign-in flows resolve via identity → user; no `merge_users!` in the auth path |
| No email-based silent linking | `from_omniauth` removed; Google lookup is by `(kind: 'google', external_id: email)` only |
| Linking requires being signed in to the target user | Verification flow runs in the context of `current_user`; new identity is bound to `current_user.id` |
| Removing an identity requires step-up auth | Re-prompt password / sign challenge / OAuth bounce before allowing revoke |
| Merging requires consent from both sides | `MergeProposal` requires `confirmed_by_a && confirmed_by_b` both fresh |
| Merging is auditable and reversible | Soft-delete + 30d window; full `ErrorLog` trail |

---

## Auth boundary cases (and how the model handles them)

| Case | Today's behavior | Under the new model |
|---|---|---|
| User signs up with email+password. Later signs in with Google (same email). | `from_omniauth` finds them by email, silently links Google. Mainline win, OPSEC-005-C hole. | Google sign-in finds no `google/<email>` identity → creates a NEW User. User notices "I have two accounts" → uses Merge flow. |
| User has Phantom-only account. Signs in with another Phantom wallet by mistake. | New User created (no collision). | Same — new User. |
| User clicks "Connect Wallet" while logged in, accidentally connects a wallet someone else has registered. | `link_solana` → `merge_users!` → session hijack risk. | Refused with "this wallet is linked to a different account". No state change. |
| User loses access to one identity (e.g. Google account deleted). | Remove via `unlink_google`. Other methods still work. | Same. `revoked_at` set on the identity row. |
| Two genuine accounts to merge. | No first-class flow; relies on auto-merge primitives that are dangerous. | `MergeProposal` flow with two-sided consent. |

---

## Scope of the implementation

Two PRs, both moderate.

**PR 1 — Read-side identity model**
- Migration + `AuthIdentity` model + backfill
- `User#identities` association
- `User.find_by_identity(kind:, external_id:)` helper
- Tests covering backfill + lookup parity with legacy fields
- No UI changes, no behavior changes — read-only foundation

**PR 2 — Cut over the auth paths**
- `SessionsController` (in engine) consults `AuthIdentity` for email/password lookup
- `OmniauthCallbacksController` consults identity, no longer calls `merge_users!`
- `AccountsController#link_solana` consults identity, no longer calls `merge_users!`
- New `IdentitiesController#create / destroy` for explicit add/remove with step-up
- New `MergeProposalsController` + `merge_proposals` table for two-sided merges
- Deprecate `merge_users!` (keep concern, gate behind a feature flag for rollback)
- Tests covering the four happy paths + four collision paths above

Estimated effort: PR 1 is ~0.5 day. PR 2 is ~2 days including tests and the merge-proposal UI.

---

## Why this matches "best in class"

This is the same shape as Auth0 / Clerk / Stytch's account-linking model. Each "Connection" is a first-class record; the "User" is a thin aggregator; linking and merging are explicit operations with two-sided consent. The reason those platforms designed it this way is exactly the OPSEC-005 attack surface: any system where sign-in collision implicitly mutates session state has a path to account takeover.

The notable Web3-specific twist: phantom-wallet identities are particularly attractive merge targets because a user signing an off-chain message can be socially engineered to sign almost anything. Refusing implicit merges removes that attack surface entirely; the only way to attach a wallet is to be signed into the target account first.

---

## What to decide before implementation

1. **Soft-delete window for merged accounts** — 30 days proposed. Pick a number.
2. **Step-up auth for identity removal** — what's required? Password re-prompt is easy; what about for users who don't have a password (wallet-only)? Probably: re-sign a wallet challenge.
3. **Merge proposal expiry** — 24h proposed.
4. **Backwards-compatibility window** — when do we delete `users.email`, `users.provider`, `users.uid`, `users.web3_solana_address`? Suggest: 90 days after PR 2 ships, behind a "migration is complete" feature flag.
5. **Engine vs satellite** — does this live in studio-engine (so future satellites inherit) or in turf-monster only? Recommended: build in turf-monster first, port to engine after one quarter of production use.

---

## Out of scope (for this proposal)

- 2FA / TOTP — orthogonal; add later as another identity kind or as a per-identity flag
- Hardware wallets beyond Phantom — same model, new `kind`
- Passkeys / WebAuthn — fits cleanly as `kind: 'passkey'` with `external_id: credential_id`
- Email verification on add (not just on signup) — recommended but separate work
