# Credential Rotation SOP (Steffon)

## Status: Active

Take ONE credential from "this value is compromised or stale" to "the new value
is live everywhere and the old one is dead." Run it top to bottom. Rotating six
secrets is this SOP six times: Phase 1 may be done once for the whole set, but
never merge two credentials' Phase 4 — a half-applied pair is unreadable from
the outside, and the symptom of each masks the other.

**Filing a NEW credential is a different act.** Vault choice, the
`<service>.<entity>.<lane>` name, the logo and permission notes, which 1Password
lane may write, and the digest read-back are all
[`credential-filing`](credential-filing.md). This SOP assumes the item already
exists and REPLACES its value; where it needs a vault write it says so and does
not restate that recipe.

**The dangerous half of a rotation is not the new value. It is the old one —
still accepted, still sitting in a store nobody enumerated.** A credential that
is live in four places and dead in a fifth is worse than a stale one: the stale
one fails everywhere, consistently, and someone notices. Phase 1 exists for that
reason and is not optional.

---

## The rule that never bends: never print the value

Not into a terminal, a transcript, a task record, a PR body, a commit message, a
log line, a Discord post, or a report. Transcripts and board records are durable
and, on a public repo, published.

| Do | Not |
|----|-----|
| `grep -rl '^VAR=' …` — prints FILE names | `grep '^VAR=' file` — prints the value |
| `heroku config --json --app X \| jq -r 'keys[]'` — key names | `heroku config --app X` while triaging a leak |
| `… --reveal \| shasum -a 256` — a digest | `op item get … --reveal` alone |
| `printf 'VAR=%s\n' "$NEW" >> file` — shell builtin, no argv | `echo` into a shared log |
| Hold the value in one shell variable, then `unset` it | Paste it into chat "just to check" |

### Compare by digest, never by eye

Two values are the same when their digests match. This is the whole verification
vocabulary of this SOP. Throughout, **`$NEW` is the shell variable holding the
newly minted value** — Phase 4.1 sets it, Phase 6 unsets it, and it never leaves
that one shell.

```bash
# what the vault now holds
op item get "<item>" --vault <vault> --fields label="<field>" --reveal | tr -d '\n' | shasum -a 256
# what you minted, in this shell
printf '%s' "$NEW" | shasum -a 256
# what an app is actually running
heroku config --json --app <app> | jq -r '.VAR // empty' | tr -d '\n' | shasum -a 256
# what a .env file holds
grep -m1 '^VAR=' <file> | cut -d= -f2- | tr -d '\n' | shasum -a 256
```

`--reveal` piped straight into a digest never lands plaintext anywhere. `--reveal`
alone does. That is the line.

**Digests are for the shell, not for the record.** `mcritchie-studio` is public
(confirm rather than assume: `gh api repos/McRitchie-Studio/mcritchie-studio --jq
.visibility`). A sha256 of a live secret is a confirmation oracle for a guessed
value, so it does not belong in a committed file, a task note, or the receipt
either. Compute it, compare it, drop it.

### `heroku config:get` is BANNED

It exits 0 and prints a bare newline for an ABSENT key, a PRESENT-BUT-EMPTY key,
and an UNAUTHENTICATED read alike — three states collapsed into one blank line,
and in a rotation those three mean three different next moves. Ask for presence
instead:

```bash
heroku config --json --app <app> | jq 'has("VAR")'   # absent -> false; present -> true, even if ""
```

(The ban is also recorded at `turf-monster/docs/SOLANA.md`, where citing
`config:get` as the verification method once got "absent" written down as
"length 0" in a review.)

### Prove the read is authenticated BEFORE you believe it

The agent shell sanitizes `HEROKU_API_KEY` at spawn, and an unauthenticated
`heroku config` read comes back **empty rather than erroring** — indistinguishable
from "the variable is unset." Every Heroku read in this SOP is preceded by a
control:

```bash
heroku auth:whoami                                  # expect alex@mcritchie.studio
heroku config --json --app <app> | jq 'length'      # expect a couple of dozen keys; 0 means the read failed
```

If `whoami` fails, pull the key inline rather than stopping:
`export HEROKU_API_KEY="$(grep -m1 '^export HEROKU_API_KEY=' ~/.zprofile | sed 's/^export HEROKU_API_KEY=//; s/^"//; s/"$//')"`.

### If a value does leak: rotate first, redact second

Deleting the note un-exposes nothing. On 2026-09-09 a full `heroku config --json`
dump — 36 keys including an RSA private key, `RAILS_MASTER_KEY`,
`SECRET_KEY_BASE`, `AWS_SECRET_ACCESS_KEY` and a live `DATABASE_URL` — was written
into a task's QA feedback and rendered on the board. The remedy is this SOP, run
once per key in the dump, highest blast radius first; the redaction is bookkeeping
afterwards.

Two rules while triaging:

- **Work from key NAMES, never the dump.** `heroku config --json --app <app> | jq
  -r 'keys[]'` gives you the enumeration; the names are not secret.
- **A pushed value is published, and a force-push does not retract it.** The
  orphaned commit stays fetchable by SHA (`gh api
  "repos/<owner>/<repo>/contents/<path>?ref=<orphaned-sha>"`). Removing it needs a
  GitHub Support purge, which is Mr. McRitchie's call — say so plainly rather than
  implying the exposure is closed.

---

## Phase 1 — Enumerate every store

Produce a written list of every place this credential exists. Do it before you
mint anything. The list is what Phase 4 walks and what the receipt records.

### 1.1 The checklist

Ask every row, every time. "Probably not" is not an answer; run the command.

| Store | How to ask | Who can write it |
|---|---|---|
| 1Password item + field | `op item list --vault <vault> --format json \| jq -r '.[].title'` | the lane that owns the vault (`credential-filing` §4) |
| Heroku config, **per app** (10 apps) | `heroku config --json --app <app> \| jq 'has("VAR")'` | any agent lane with the Heroku agent key |
| GitHub **Actions** secrets, per repo | `gh secret list -R McRitchie-Studio/<repo>` | **operator only** — see 1.2 |
| GitHub **Dependabot** secrets, per repo | `gh secret list --app dependabot -R McRitchie-Studio/<repo>` | **operator only** — separate store |
| `.env` on primaries **and every desk** | `grep -rl '^VAR=' /Users/alex/projects/*/.env /Users/alex/projects/*/.worktrees/*/.env` | you, per file |
| Env snapshots on disk | `ls -l /Users/alex/projects/mcritchie-studio/tmp/env-snapshot-*.json` | you |
| The **public half**, wherever it is registered | on-chain account, provider dashboard, webhook config, a pubkey written into a doc | often a third party — the slow step |

### 1.2 What the commands actually return here

**Heroku — the fleet is ten apps, verified 2026-09-09.** Sweep all of them; a
credential you "know" is hub-only has a way of being in QA too.

```bash
heroku auth:whoami
for app in mcritchie-studio mcritchie-studio-qa turf-monster-mainnet turf-monster-qa \
           mcritchie-industries mcritchie-industries-qa rolio-prod rolio-qa tax-studio moms-app; do
  printf '%-26s keys=%-4s has=%s\n' "$app" \
    "$(heroku config --json --app "$app" | jq 'length')" \
    "$(heroku config --json --app "$app" | jq 'has("VAR")')"
done
```

`keys=0` means that read failed; fix the auth before reading `has=` as an answer.

**1Password — your lane sees only its own vaults.** On 2026-09-09 the ambient
agent token listed exactly four: `studio-agents`, `industries-agents`,
`family-agents`, `Commercial Welding`. `studio-agents-admin` and
`studio-applications` did NOT appear, and both exist. Absence from `op vault list`
means your lane cannot see the vault, never that the vault is not there. Assign the
right lane (`credential-filing` §4) and re-run. On `(101) You do not have
permission`, check `op service-account ratelimit` first — the daily cap is 1,000
reads account-wide and shared by every lane, and a spent quota refuses exactly like
a missing grant.

**GitHub — two stores, and neither is yours to write.** Measured 2026-09-09: both
commands return `HTTP 403: Resource not accessible by integration` under the agent
GitHub App installation token, because that App has no secrets permission. The two
calls hit distinct REST namespaces — `/actions/secrets` and `/dependabot/secrets`
— which is the plainest proof they are separate stores. A value mirrored into
Actions is **not** in Dependabot; `studio-engine`'s `consumer-ci.yml` consumes
`MCRITCHIE_AGENT_APP_ID` and `MCRITCHIE_AGENT_PRIVATE_KEY`, and a Dependabot-raised
PR runs that workflow with the Dependabot copy.

So the GitHub store is an **operator step**, and it is the one that will stall you
if you discover it at the end. Plan it into Phase 4: Mr. McRitchie updates it at
`Settings → Secrets and variables → Actions`, then the `Dependabot` tab of the same
page, per repo. Give him the repo list and the secret names — never the value in
chat; hand it over per `credential-filing` §5 (`read -rs`, clipboard, cleared after).

**`.env` — there are far more copies than you think.** `bin/agent-worktree` COPIES
the primary `.env` into each desk at creation, so a desk holds a frozen snapshot
from the day it was born. Measured 2026-09-09: 21 desks under `mcritchie-studio`
and 29 under `turf-monster`, each with its own `.env` — a desk created before the
rotation still holds the compromised value. `bin/ecosystem-build` re-fetches
`.env` for the PRIMARIES only; it never touches `.worktrees/*/.env`.

```bash
grep -rl '^VAR=' /Users/alex/projects/*/.env /Users/alex/projects/*/.worktrees/*/.env 2>/dev/null
```

`-l` prints file names. Never drop it.

**Env snapshots.** `bin/ecosystem-build` Phase 9 writes each primary's whole `.env`
raw into `mcritchie-studio/tmp/env-snapshot-YYYY-MM-DD.json` (chmod 600,
gitignored) as a Heroku-independent fallback. Every snapshot older than the
rotation contains the dead value. They are not a store you update — they are a
store you **delete or knowingly keep**, and the receipt records which.

### 1.3 Write the list down now

One line per store: where it is, who can write it, and whether it holds the value
or only the public half. This list is the rotation. Everything after Phase 1 is
walking it.

---

## Phase 2 — The data question

> **What did the old value authenticate or ENCRYPT, and does that artefact survive
> the change?**

Ask it before minting. It is the half that gets skipped, and the answer decides
whether the rotation is a config edit or a migration.

| Answer | Example | What it costs you |
|---|---|---|
| Nothing survives — it only ever authenticated | a bearer API key, `HEROKU_API_KEY`, an SES key | Nothing extra. Rotate and move on. |
| An artefact must be MIGRATED | `RAILS_MASTER_KEY`, `MANAGED_WALLET_ENCRYPTION_KEY` | A re-encryption step, inside a window where BOTH values are available |
| An artefact DIES | `SECRET_KEY_BASE` | An announced outage: sessions and signed URLs stop verifying |
| A PUBLIC half is registered elsewhere | a Solana signing keypair, a webhook signing secret | Phase 3 — the registration moves FIRST, and it is the long pole |

The three that cost something, concretely:

- **`RAILS_MASTER_KEY` re-encrypts, it does not replace.** `config/credentials.yml.enc`
  is readable only under the OLD key, and the new key is worthless against it. So:
  open the file with the current key (`EDITOR='code --wait' bin/rails
  credentials:edit`), copy the plaintext to a scratch file OUTSIDE the repo, delete
  `config/credentials.yml.enc` and `config/master.key`, re-run `credentials:edit` to
  mint a fresh pair, paste the plaintext back, save, commit the new `.enc`, then
  shred the scratch file. There is **no overlap window** for this one: the new
  config var and the new committed ciphertext must go live in the same deploy, or
  the app boots against a file it cannot read. Do it per app. Whether SESSIONS
  survive depends on `secret_key_base`, not on the master key: paste the same
  plaintext back and it is unchanged, so signed cookies keep verifying. Regenerate
  credentials from scratch and it changes — then the `SECRET_KEY_BASE` row below
  applies too, and you owe the announcement.
- **`SECRET_KEY_BASE` invalidates artefacts.** Every signed or encrypted cookie,
  session, and signed URL derived from it stops verifying the moment the new value
  is live — users are logged out and outstanding magic links (`Studio::Link`) die.
  Pick a low-traffic window, tell Mr. McRitchie people will be logged out, and do
  not schedule anything whose verification needs a logged-in session in the same
  window.
- **`MANAGED_WALLET_ENCRYPTION_KEY` re-encrypts row data.** Every managed wallet's
  Ed25519 secret is encrypted under a key derived from it. Two-key window: set the
  new value under a SECOND config var, run the re-encrypt task to completion, then
  promote the new value and unset the temporary one. Lose the old value before the
  task finishes and every managed wallet is unrecoverable.

If the answer is "an artefact must be migrated", the old value stays retrievable
until the migration is verified. That constraint outranks the urge to revoke early.

---

## Phase 3 — Order the moves

> **Rotate the REGISTRATION before the CONFIG. Never leave a window where the
> running app holds a credential nothing accepts.**

The naive order — set the new value, then update everything else — inverts this
and breaks the app for the length of the gap. The gap is never as short as
planned, because the registration step is usually the one with another party in it.

### The worked example: the Alex Bot signing key

The Alex Bot key is shared by `turf-monster-qa` and `turf-monster-mainnet`, and its
PUBLIC half is a registered on-chain signer in turf-vault's `VaultState`. Rotating
it is not a `heroku config:set`. Read the program, not the intuition
(`turf-vault/programs/turf_vault/src/instructions/update_signers.rs`, and
`validate_multisig` at `programs/turf_vault/src/state.rs:159`):

- `update_signers(new_signers: [Pubkey; 3])` does `vault.signers = new_signers` — a
  **whole-set replace across three fixed slots**. There is no fourth slot, so every
  legal rotation EVICTS somebody.
- Auth is 2-of-3 of the CURRENT signers: `validate_multisig` is `s1 != s2 &&
  is_signer(s1) && is_signer(s2)` — two DISTINCT current signers must sign.
- Signer continuity (OPSEC-027) requires **both** cosigners who authorized THIS
  update to survive it. So the evictable slot is exactly the one that did NOT
  cosign — WHO you may evict is decided by who shows up to sign, and there are
  three legal rotations, one per choice of cosigning pair.
- The set must also contain no duplicates and no `Pubkey::default()`.

**There is no overlap window on-chain, and that is by construction.** Because the
instruction replaces the whole set across three fixed slots, the new pubkey
arrives and the old one leaves in the SAME transaction. Do not plan a
"add now, remove later" pair for a COMPROMISED key — the only way to hold both at
once is to evict a third signer (e.g. Mason) for the duration, which buys a
rollback window by taking a slot from someone who did nothing wrong. Reserve that
two-step shape for a planned move (a signer going to a hardware wallet); for a
compromise, swap directly and accept that the rollback is another 2-of-3
`update_signers`.

Setting the config var first leaves the app signing as an identity the vault does
not recognise. That is not "isolated"; it is BROKEN, and it is broken for both QA
and mainnet at once. The correct order:

1. Mint the new keypair. Nothing is live yet.
2. Get the registration updated: run `update_signers` with the new pubkey in the
   evicted slot, cosigned by the two who stay. **There is no operational script for
   this** — `update_signers` appears in `turf-vault/tests/turf_vault.ts` and nowhere
   in `scripts/`. Budget for writing the transaction and for two humans at Phantom.
3. VERIFY the new identity is accepted: read `VaultState` (`seeds = [b"vault"]`)
   back and confirm the new pubkey is in `signers`.
4. ONLY THEN set the config var on each consuming app.
5. Phase 6. Note the on-chain eviction ALREADY happened at step 2 — for this
   credential Phase 6 is only clearing the dead secret out of the stores that
   still hold it.

### The second shape: one identity, many consumers

`agent.aws` is one IAM user (`mcritchie-s3`) backing Active Storage for the hub,
Turf Monster, Industries and moms-app. Nothing is registered anywhere, so Phase 3
is easy — but every consumer must move inside ONE window, or the apps left behind
are authenticating with a key you are about to revoke. AWS gives you a real
overlap here: mint a second access key, deploy it everywhere, verify everywhere,
and only then delete the first. Prefer that shape whenever the provider allows two
live credentials at once; it turns Phase 6 into a formality.

### The general order

1. Mint the new value (nothing is live).
2. File it in 1Password (the durable copy exists before anything depends on it).
3. Update the registration of the public half, and PROVE it is accepted.
4. Write the runtime stores: Heroku per app, GitHub Actions and Dependabot, `.env`
   and desks.
5. Migrate or retire the data (Phase 2's answer).
6. Verify liveness store by store.
7. Retire the old value at the source. **Point of no return.**

**Read the Rollback section below before you execute step 1.** It is short, and
knowing where the door closes is what lets you move quickly up to that point.

---

## Phase 4 — Execute

Hold the new value in ONE shell variable (`$NEW`) from here through Phase 5, and
`unset` it in Phase 6. Phase 5 digests against it, so a shell that forgets it
early cannot verify anything.

### 4.1 Mint

At the provider, by its own recipe. Two rules: never let the value reach a
transcript, and if the value starts in Mr. McRitchie's hands, it is `read -rs T`
in HIS terminal per `credential-filing` §5 — `-r` because a backslash in a token
survives it, and without it `read` corrupts the value silently.

### 4.2 File it in 1Password FIRST

Before any consumer depends on it. Overwrite the item's value field, and update
`authorization-id`, `used-by`, and the `scope`/`CAN`/`CANNOT` notes in the same
edit if the new credential's scope differs — a permission matrix describing the
previous key is worse than none.

Then read it back by digest (the pair of commands under "Compare by digest").
Whoever held the source value runs the comparison; if that is Mr. McRitchie, he
runs both lines in his terminal against his `$T` and `unset T` only after they
match. A shell that has already forgotten the value digests the empty string,
which false-mismatches a credential that was filed correctly.

**Overwriting a 1Password field is reversible** — the item keeps version history.
That is why this store goes first.

### 4.3 Update the registration, and prove it is accepted

Only if Phase 2 said a public half is registered. Do the update, then make the
system that must accept the new identity actually accept it: read the on-chain
account back, send one signed request the far side verifies, fire one test
webhook. A registration that "looks updated" in a dashboard is not a proof.

### 4.4 Write the runtime stores

**Heroku, per app.** One `config:set` per app, from the shell variable so the
value never appears in the command you type:

```bash
heroku config:set "VAR=$NEW" --app <app>
```

Note this puts the value on `config:set`'s argv, readable via `ps` by same-user
processes for the life of the call — acceptable on this single-operator machine,
stated so the recipe is not mistaken for airtight. `config:set` restarts the app's
dynos; a worker mid-job may still finish under the old value.

**GitHub Actions and Dependabot.** The operator step from Phase 1.2. Give Mr.
McRitchie the repo list and the secret names, hand the value over off-transcript,
and confirm BOTH tabs. A rotation that updates Actions and forgets Dependabot goes
green on every push and red only on the next Dependabot PR, days later, in a
workflow nobody is watching.

**`.env` on primaries.** `bin/ecosystem-build` re-fetches the primaries from
Heroku, which is the sanctioned refresher once Heroku is correct.

**`.env` on desks.** Untouched by that, and there are dozens. Finished desks are
better reclaimed than rewritten — that is [`clean-infra`](clean-infra.md). Desks
that must keep running get the one line replaced, printing nothing:

```bash
for f in /Users/alex/projects/*/.worktrees/*/.env; do
  [ -f "$f" ] || continue
  grep -q '^VAR=' "$f" || continue
  tmp=$(mktemp); grep -v '^VAR=' "$f" > "$tmp"; printf 'VAR=%s\n' "$NEW" >> "$tmp"
  mv "$tmp" "$f"; chmod 600 "$f"
done
```

**Env snapshots.** Delete the ones that predate the rotation, or record in the
receipt that you kept them and why:

```bash
rm -f /Users/alex/projects/mcritchie-studio/tmp/env-snapshot-*.json
```

### 4.5 Migrate the data

Phase 2's answer, executed now — the re-encryption, or the announced invalidation.
Do it before Phase 6: every migration in Phase 2 needs the OLD value to still work.

---

## Phase 5 — Verify liveness, store by store

Liveness means **the new value is the one in use**, proved by something only the
new credential could produce. Absence of an error is not that.

| Store | The proof |
|---|---|
| 1Password | filed field's digest == `$NEW`'s digest |
| Heroku, per app | `.VAR`'s digest == `$NEW`'s digest, AND an authenticated call from a dyno: `heroku run --exit-code --app <app> bin/rails runner '<one call only the new credential can make>'` |
| GitHub Actions | re-run the workflow that consumes it and read the run's conclusion — plus confirm the step that uses it actually ran |
| GitHub Dependabot | the Dependabot tab shows the secret updated today, and the next Dependabot PR's `consumer-ci` run is green |
| `.env` / desks | per-file digest match, from the sweep in Phase 1.2 |
| Registration | one signed request the far side ACCEPTS, or the account read back on-chain |

### What does NOT count as verification

- **A green deploy.** `bin/release.rb`'s post-deploy check derives its verdict
  solely from `heroku run --exit-code`'s status and never parses the output. Green
  proves exit 0 and nothing else.
- **`heroku config:get` returning something.** Banned above, and doubly blind on an
  unauthenticated shell: empty twice over.
- **An empty `heroku config` read.** Unauthenticated reads come back empty rather
  than erroring. Always read the control (`jq 'length'`) first.
- **A task that exits 0.** A per-record `rescue StandardError` turns a total
  credential failure into a counter. Measured: `turf-monster-qa` has NO AWS config
  vars at all, so every S3 write there raises `Aws::Errors::MissingCredentialsError`
  — and `nfl:upload_headshots` printed `cached: 0, failed: 2849` and **exited 0**.
  Read the counters, not the exit code.
- **"The app is still up."** Dynos may be serving the old value from before the
  restart, or the flow you are watching may not touch this credential at all.

---

## Phase 6 — Retire the old value

**This is the point of no return: revoking the old credential AT THE SOURCE.**
Everything before it is reversible; nothing after it is.

Do it only when Phase 5 passed for EVERY store on the Phase 1 list. Where the
credential was migrated rather than replaced (Phase 2), give it 24-48 hours of
confirmed normal operation first.

| Source | Revoke with |
|---|---|
| Heroku authorization | `heroku authorizations` then `heroku authorizations:revoke <id>` |
| AWS access key | delete the old access key for that IAM user in the console or CLI |
| Provider API key | the provider's console — "revoke", not "hide" |
| On-chain signer | **already done in 4.3** — the whole-set `update_signers` evicted the old pubkey in the same transaction. There is no second eviction. Reversible only by another 2-of-3 `update_signers`, so keep the old secret filed until Phase 5 passes. |
| 1Password field | already overwritten in 4.2 — **still recoverable via item history**, so this is not the point of no return |

Then clear the shell: `unset NEW` (and `unset T` if Mr. McRitchie still holds one).

---

## Rollback

**Before Phase 6 there is a real rollback**, because the old credential still
works. Walk Phase 4 backwards: put the old value back in the runtime stores first
(Heroku, GitHub, `.env`), then revert the registration, then restore the 1Password
field from item history. Re-run Phase 5 against the old value. Then stop and work
out what failed before trying again.

**After Phase 6 there is none.** The path is forward only: mint again, and treat
it as an incident — a revoked credential with no working replacement is an outage,
and the clock is running.

The half-done shapes, and the way out of each:

| Symptom | What happened | Do this |
|---|---|---|
| One app 401s, the rest are fine | a `config:set` was missed | re-run the ten-app `has()` sweep from 1.2; digest-compare each |
| Everything is fine until a Dependabot PR | Actions updated, Dependabot not | operator updates the Dependabot tab |
| The app authenticates but the far side rejects it | config moved before the registration | put the OLD value back on the app, finish Phase 4.3, then re-flip |
| The app boots but cannot read credentials | new `RAILS_MASTER_KEY` against old ciphertext | restore the old key; redo Phase 2's re-encryption so key and `.enc` deploy together |
| A desk fails while production is healthy | a stale desk `.env` | re-run the desk loop in 4.4, or reclaim the desk |
| Nothing works and the old value is gone | Phase 6 ran before Phase 5 passed | forward only — mint again; this is why Phase 6 is last |

---

## Phase 7 — The receipt

A rotation nobody can audit later is one somebody will redo. Append one row to the
**Rotation log** table in
[`secrets-rotation.md`](../../../system/secrets-rotation.md), and commit it through
the normal cycle:

`| <YYYY-MM-DD, UTC> | <1Password item name> | <why> | <stores updated> | <how verified> | <old value revoked: yes/no + when> | <task URL> |`

Also update the item's row in
[`credential-inventory.md`](../../../modules/credential-inventory.md) when the
rotation changed a FACT recorded there — a new authorization id, a new scope, a new
consumer. Do not touch it when only the value changed; the inventory is a census of
locations, not of values.

**No values. No digests. No key material of any kind** — the repo is public, and
the receipt is a record of WHAT and WHEN, never of what the value is.

---

## Background — not needed to execute

- `docs/agents/system/secrets-rotation.md` also carries per-credential recipes
  (1Password service-account token, `HEROKU_API_KEY`, `RAILS_MASTER_KEY`,
  `MANAGED_WALLET_ENCRYPTION_KEY`, `SOLANA_ADMIN_KEY`, Anthropic, X). They are
  accelerators for a specific secret; this SOP is the procedure, and where the two
  disagree, this file wins and the recipe gets fixed in the same pass.
- `docs/agents/modules/credentials.md` — the access contract and the two 1Password
  lanes.
- `docs/agents/modules/credential-inventory.md` §"Shared AWS identity" — what
  sharing one IAM user across four brands costs at rotation time.
- `turf-monster/docs/SOLANA.md` — the signer set, the Squads upgrade authority, and
  the `config:get` ban in its original context.
