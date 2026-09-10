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

## Placeholders, and the one variable that is real

Everything in angle brackets is a placeholder you substitute before running
anything. **`<VAR>` is the credential's environment-variable name** (e.g.
`SOLANA_ADMIN_KEY`, `AWS_SECRET_ACCESS_KEY`) — it is the placeholder you
will substitute most often, and a command run with `<VAR>` left in it finds
nothing and tells you the credential is not there. `<item>`, `<field>` and
`<vault>` name its 1Password home; `<app>` and `<file>` name one target.

`$NEW`, `$APPS` and `$ROTATED_AT` are **real shell variables this SOP assigns** —
leave those exactly as written. Every snippet that could damage something opens
by refusing to run until they are set.

---

## The rule that never bends: never print the value

Not into a terminal, a transcript, a task record, a PR body, a commit message, a
log line, a Discord post, or a report. Transcripts and board records are durable
and, on a public repo, published.

| Do | Not |
|----|-----|
| `grep -rl '^<VAR>=' …` — prints FILE names | `grep '^<VAR>=' <file>` — prints the value |
| `heroku config --json --app X \| jq -r 'keys[]'` — key names | `heroku config --app X` while triaging a leak |
| `… --reveal \| digest` — a truncated digest | `op item get … --reveal` alone |
| `printf '<VAR>=%s\n' "$NEW" >> file` — shell builtin, no argv | `echo` into a shared log |
| Hold the value in one shell variable, then `unset` it | Paste it into chat "just to check" |

### Compare by digest — and a digest of nothing is not a comparison

Two values are the same when their digests match. This is the whole verification
vocabulary of this SOP, and it has one failure mode that is worse than being
wrong: **an empty value digests to a perfectly good-looking digest, and two empty
values MATCH.**

```text
sha256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

An absent variable, an unset config var, a `.env` line stripped to `<VAR>=`, and a
read that failed all produce that digest. So a comparison either side can satisfy
with nothing certifies nothing — it will report MATCH after a rotation has wiped
the value out of every store it touched. Every comparison in this SOP therefore
goes through one helper that **refuses to digest an empty value**:

```bash
# Paste this into the shell that will run Phases 4 and 5, before anything else.
digest() {
  local v
  v=$(cat)
  if [ -z "$v" ]; then
    printf 'EMPTY — refusing to digest nothing. This comparison is VOID; stop.\n' >&2
    return 1
  fi
  printf '%s' "$v" | shasum -a 256 | cut -c1-16
}
```

It prints a 16-hex-character prefix, which is what you compare; it exits non-zero
and prints no digest when there is nothing to digest. **If any read below returns
EMPTY, that is the answer — do not proceed to the next store.** Never fall back to
a bare `shasum` to "get past" an EMPTY: that is the exact substitution that turns a
wipe into a green verification.

```bash
# what the vault now holds
op item get "<item>" --vault <vault> --fields label="<field>" --reveal | digest
# what you minted, in this shell
printf '%s' "$NEW" | digest
# what an app is actually running
heroku config --json --app <app> | jq -r '.["<VAR>"] // empty' | digest
# what a .env file holds — strip an optional surrounding quote pair, which
# `cut -d= -f2-` alone leaves in and which then false-mismatches: 4 of the 22
# keys in turf-monster/.env are quoted, CDP_API_KEY_SECRET among them
grep -m1 '^<VAR>=' <file> | sed -E 's/^[^=]+=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' | digest
```

`--reveal` piped straight into a digest never lands plaintext anywhere. `--reveal`
alone does. That is the line.

**Whose shell holds `$NEW`.** One shell owns it: **the shell that runs Phases 4
and 5**, set in 4.1 and unset in Phase 6. When the value starts in Mr. McRitchie's
hands he holds it as `$T` in HIS terminal (`credential-filing` §5), and that is a
DIFFERENT shell — so either he runs Phases 4 and 5 himself against `$T`, or he
`read -rs NEW`s it into the rotating shell. What must never happen is one shell
writing the stores while another holds the value: the writing shell then has an
empty `$NEW`, and everything it touches gets emptied.

**Digests are for the shell, not for the record.** `mcritchie-studio` is public
(confirm rather than assume: `gh api repos/McRitchie-Studio/mcritchie-studio --jq
.visibility`). A sha256 of a live secret is a confirmation oracle for a guessed
value, so it does not belong in a committed file, a task note, or the receipt
either. Compute it, compare it, drop it.

### `heroku config:get` is BANNED

Measured 2026-09-09: for an ABSENT key it exits **0** and prints one byte — a bare
newline — which is byte-for-byte what a PRESENT-BUT-EMPTY key prints. Two states
that mean two different next moves, collapsed into one blank. A FAILED read is a
third: on its own it exits 1 and errors loudly, but **piped into anything it
collapses into the same blank**, because the error goes to stderr and the pipeline
reports the last command's status. Ask for presence instead:

```bash
heroku config --json --app <app> | jq 'has("<VAR>")'   # absent -> false; present -> true, even if ""
```

(The ban is also recorded at `turf-monster/docs/SOLANA.md`, where citing
`config:get` as the verification method once got "absent" written down as
"length 0" in a review.)

### Prove the read is authenticated BEFORE you believe it

A failed Heroku read is loud on stderr but **silent on stdout**, and a pipeline
throws away both halves of the noise. Measured 2026-09-09 on this machine:

| Token state | exit | stderr | stdout |
|---|---|---|---|
| invalid | 1 | `Error: The token provided to HEROKU_API_KEY is invalid.` | **0 bytes** |
| absent | 1 | `heroku: Press any key to open up the browser to login` | **0 bytes** |

So `heroku config --json --app <app> | jq -r '…'` gives you nothing either way:
`jq` never sees the error, and the pipe reports `jq`'s status, not `heroku`'s. Feed
that nothing to a bare `shasum` and out comes `e3b0c442…` — a failed read wearing
the digest of a verified empty value. The `digest` helper turns it into a loud EMPTY instead, and
every Heroku read in this SOP is still preceded by a control:

```bash
heroku auth:whoami                                  # expect alex@mcritchie.studio
heroku config --json --app <app> | jq 'length'      # expect a couple of dozen keys; 0 means the read failed
```

`HEROKU_API_KEY` is **not** sanitized in an agent shell — measured present, 65
chars, in the shell that wrote this. If `whoami` fails anyway, pull the key inline
rather than stopping:
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
| Heroku config, **per app** (10 apps) | `heroku config --json --app <app> \| jq 'has("<VAR>")'` | any agent lane with the Heroku agent key |
| GitHub **Actions** secrets, per repo | `gh secret list -R McRitchie-Studio/<repo>` | **operator only** — see 1.2 |
| GitHub **Dependabot** secrets, per repo | `gh secret list --app dependabot -R McRitchie-Studio/<repo>` | **operator only** — separate store |
| `.env` on primaries **and every desk** | `grep -rl '^<VAR>=' /Users/alex/projects/*/.env /Users/alex/projects/*/.worktrees/*/.env` | you, per file |
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
    "$(heroku config --json --app "$app" | jq 'has("<VAR>")')"
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
from the day it was born. Measured 2026-09-09: 25 desks under `mcritchie-studio`
and 36 under `turf-monster`, **57 `.env` files across them** — a desk created
before the rotation still holds the compromised value. Treat those counts as
illustrative and re-run the sweep; desks open and close daily. `bin/ecosystem-build` re-fetches
`.env` for the PRIMARIES only; it never touches `.worktrees/*/.env`.

```bash
grep -rl '^<VAR>=' /Users/alex/projects/*/.env /Users/alex/projects/*/.worktrees/*/.env 2>/dev/null
```

`-l` prints file names. Never drop it — and substitute `<VAR>` before you run it,
or it matches nothing and you will write "not in any `.env`" into your Phase 1
list about a credential that is in fifty-seven of them.

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
| An artefact must be MIGRATED | `RAILS_MASTER_KEY` | A re-encryption step, inside a window where BOTH values are available |
| An artefact must be MIGRATED, by code that must be DEPLOYED first | `MANAGED_WALLET_ENCRYPTION_KEY` | A two-key window and a verified re-seal — and **no rotation at all** until the running release carries them. See the bullet below. |
| An artefact DIES | `SECRET_KEY_BASE` | An announced outage: sessions and signed URLs stop verifying |
| A PUBLIC half is registered elsewhere | a Solana signing keypair, a webhook signing secret | Phase 3 — the registration moves FIRST, and it is the long pole |

The three that cost something, concretely:

- **`RAILS_MASTER_KEY` re-encrypts, it does not replace.** `config/credentials.yml.enc`
  is readable only under the OLD key, and the new key is worthless against it. So:
  open the file with the current key (`EDITOR='code --wait' bin/rails
  credentials:edit`), copy the plaintext to a scratch file OUTSIDE the repo, delete
  `config/credentials.yml.enc` and `config/master.key`, re-run `credentials:edit` to
  mint a fresh pair, paste the plaintext back, save, commit the new `.enc`, then
  delete the scratch file. **There is no `shred` on macOS, and `rm -P` is a
  documented no-op here** (`man rm`: "This flag has no effect. It is kept only for
  backwards compatibility with 4.4BSD-Lite2"), so do not write a command that
  pretends to overwrite. Create it under a private umask and remove it:
  `(umask 077; : > "$TMPDIR/creds.$$")` … then `rm -f "$TMPDIR/creds.$$"`. On APFS
  the honest guarantee is *unlinked*, not *erased* — so keep the window short, keep
  it out of the repo and out of anything backed up, and if the disk is ever suspect
  treat the plaintext as exposed and rotate again. There is **no overlap window**
  for this one: the new config var and the new committed ciphertext must go live in
  the same deploy, or the app boots against a file it cannot read. Do it per app.
  SESSIONS are a separate question, and on production the answer is "they survive,
  full stop": `SECRET_KEY_BASE` is its OWN Heroku config var on both
  `mcritchie-studio` and `turf-monster-mainnet` (measured 2026-09-09), and an
  environment `SECRET_KEY_BASE` is what Rails uses — so the master key cannot reach
  the session secret there at all. Where it is NOT set separately, sessions still
  survive a master-key rotation as long as you paste the same plaintext back;
  regenerate credentials from scratch and `secret_key_base` changes, and then the
  `SECRET_KEY_BASE` row below applies too and you owe the announcement.
- **`SECRET_KEY_BASE` invalidates artefacts.** Every signed or encrypted cookie,
  session, and signed URL derived from it stops verifying the moment the new value
  is live — users are logged out and outstanding magic links (`Studio::Link`) die.
  Pick a low-traffic window, tell Mr. McRitchie people will be logged out, and do
  not schedule anything whose verification needs a logged-in session in the same
  window.
- **`MANAGED_WALLET_ENCRYPTION_KEY` is a migration behind a deploy gate.** Every
  managed wallet's Ed25519 secret is sealed under a key derived from it. **The code
  must be DEPLOYED before the key is rotated**: on a release older than
  `managed-wallet-key-rotation` the app reads one key, and the migration task reports
  success while every wallet becomes undecryptable. Do not run the generic Phase 4
  for it — run [§2.1](#21-managed_wallet_encryption_key--deploy-first-then-migrate),
  which replaces 4.1 through 4.5 for this key.

If the answer is "an artefact must be migrated", the old value stays retrievable
until the migration is verified. That constraint outranks the urge to revoke early.
**And if the migration machinery does not exist IN THE RUNNING RELEASE, the
rotation does not happen** — you cannot runbook your way around a missing decrypt
path, and merged code is not running code. Prove the two-key window exists on the
app itself (§2.1's Gate 0 is the shape of that proof), not by reading a runbook
that says it does.

### 2.1 `MANAGED_WALLET_ENCRYPTION_KEY` — deploy first, then migrate

Until `managed-wallet-key-rotation` shipped, this key had no two-key window, and this
SOP refused to rotate it. Any release that predates that change still behaves the
old way:

| What a rotation needs | Before `managed-wallet-key-rotation` | Since |
|---|---|---|
| A second key the app can decrypt with | `Solana::Keypair` read `MANAGED_WALLET_ENCRYPTION_KEY` and only that | `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS` opens old rows. It never seals. |
| A task that re-seals OLD → NEW | `solana:reencrypt_managed_wallets` skipped every row carrying `v2:`, which is every row | The same task re-seals each row the current key alone cannot open, reads it back under the current key alone, and writes it by compare-and-swap |
| A way to tell it finished | None: it printed `0 migrated, N already v2, 0 failed` and exited 0 | It prints `total / migrated / already-new / failed`, recounts every row under the new key alone, and exits 1 unless all of them verify. `solana:verify_managed_wallet_keys` is the read-only count. |

**Gate 0 — the code must be DEPLOYED before the key is rotated.** Merged is not
deployed. Only the release RUNNING on the app reads the key. On an older release,
the config write in step 5 leaves every managed wallet undecryptable, and the
migration reports success. Prove the code is running, per app that holds the key,
before you mint anything:

```bash
heroku run --exit-code --app turf-monster-mainnet bin/rails solana:verify_managed_wallet_keys
heroku run --exit-code --app turf-monster-mainnet bin/rails runner \
  'puts User.where.not(encrypted_web2_solana_private_key: [nil, ""]).count'
```

`Don't know how to build task` means the release predates the code: **stop — the
answer is no** until it is deployed. The gate passes only on the line `VERIFIED --
N of N row(s) open under the current key alone.` The second command counts the same
rows a different way, so the verifier is not grading itself; the two numbers must
match. Write N down: every later count is checked against it. Each app that holds
the key is its own migration — its own rows, rehearsal, and count.

**1. Mint (replaces 4.1)** straight into the shell, never onto the screen. The
task refuses anything but 64 hex characters.

```bash
NEW=$(ruby -e 'require "securerandom"; print SecureRandom.hex(32)')
printf '%s' "$NEW" | digest
```

**2. Hold the OLD value, and prove it is the LIVE one.** Step 5 overwrites the only
copy the rows are sealed under, so a wrong `$OLD` loses the key for good.

```bash
OLD=$(op item get agent.managed_wallet --vault studio-agents --fields label="encryption key" --reveal)
printf '%s' "$OLD" | digest
heroku config --json --app turf-monster-mainnet | jq -r '.["MANAGED_WALLET_ENCRYPTION_KEY"] // empty' | digest
[[ "$OLD" =~ ^[0-9a-fA-F]{64}$ ]] && echo "OLD: 64 hex" || echo "OLD: NOT 64 hex"
```

The two digests must match, and neither may print EMPTY. **A mismatch is a stop.**
If `$OLD` is not 64 hex, stop and route to Jasper: the rehearsal and the rollback
both need a 64-hex key.

**3. Rehearse with the app untouched.** Hand both keys to ONE one-off dyno; the
app's config does not change. Both values sit on `heroku run`'s argv for the length
of the call, the same exposure 4.4 accepts.

```bash
: "${NEW:?NEW is not set -- go back to step 1}" && : "${OLD:?OLD is not set -- go back to step 2}" &&
[ "$NEW" != "$OLD" ] &&
heroku run --exit-code --app turf-monster-mainnet \
  --env "DRY_RUN=1;MANAGED_WALLET_ENCRYPTION_KEY=$NEW;MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD" \
  bin/rails solana:reencrypt_managed_wallets
```

Read the output; the exit code alone proves nothing. The header must say
`ROTATION`. The counts must read `total: N  would-migrate: N  already-new: 0
failed: 0`, and the last line must start `DRY RUN CLEAN`. `already-new` above 0 on a
first rehearsal means the keys are swapped. A `FAILED` line means `$OLD` does not
open that row. `REFUSED` names the rule the new key broke. In every one of those
cases, **stop** — nothing has changed yet.

**4. File both (replaces 4.2).** Add a `previous encryption key` field holding `$OLD`
to `agent.managed_wallet` FIRST. Then replace `encryption key` with `$NEW`, by the
4.2 recipe. Read both back by digest.

**5. Write the app in ONE command (replaces 4.4) — never the generic loop.** One
release, one restart, and the app never runs on the new key alone. Two commands
would open a window in which every existing wallet fails to decrypt.

```bash
: "${NEW:?refusing -- NEW is empty}" && : "${OLD:?refusing -- OLD is empty}" &&
[ "$NEW" != "$OLD" ] &&
heroku config:set "MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD" \
  "MANAGED_WALLET_ENCRYPTION_KEY=$NEW" --app turf-monster-mainnet
```

From this moment new wallets are sealed under `$NEW`, so **`$NEW` never leaves the
app again** — not even in a rollback.

**6. Migrate (replaces 4.5).** Dry-run once more from the app's own config, then run
it for real:

```bash
heroku run --exit-code --app turf-monster-mainnet --env "DRY_RUN=1" bin/rails solana:reencrypt_managed_wallets
heroku run --exit-code --app turf-monster-mainnet bin/rails solana:reencrypt_managed_wallets
```

The real run is complete only on all three of: `total: T  migrated: M  already-new:
A  failed: 0` with M + A = T; the line `Read-back: T of T row(s) open under the
current key alone`; and a last line starting `COMPLETE`. T may exceed N by the
wallets minted since step 5; those count as already-new. `NOT COMPLETE` is safe:
every row is whole, and both keys still open it. Read the `FAILED` lines and re-run.
It is never a reason to go on to Phase 6.

Phase 5 and Phase 6 for this key are their rows in those tables. Know, too, what a
rotation does NOT do: it re-seals the envelope, never a wallet's private key. Every
ciphertext sealed under the old key stays openable with it forever — in a Postgres
backup, a fork, a follower, or a dump. So a COMPROMISED key is an incident, not a
rotation: rotate, move funds to fresh wallets, destroy the pre-rotation backups, and
escalate to Mr. McRitchie.

---

## Phase 3 — Order the moves

> **Rotate the REGISTRATION before the CONFIG. Never leave a window where the
> running app holds a credential nothing accepts.**

The naive order — set the new value, then update everything else — inverts this
and breaks the app for the length of the gap. The gap is never as short as
planned, because the registration step is usually the one with another party in it.

### The worked example: the Alex Bot signing key

The Alex Bot key is `SOLANA_ADMIN_KEY` on `turf-monster-qa` and
`turf-monster-mainnet`. Its PUBLIC half is registered in **two independent places**,
and its SECRET half is consumed by a third. Phase 1 must list all three, because
each is updated by a different mechanism and missing one leaves real authority with
the key you just rotated out:

| Where the Alex Bot key is registered or consumed | Updated by | Verified 2026-09-09 |
|---|---|---|
| turf-vault `VaultState.signers` — contest/treasury 2-of-3 | `update_signers` (on-chain, 2-of-3) | `turf-monster/docs/SOLANA.md` signer list |
| turf-vault **Squads V4 2-of-3 — MAINNET PROGRAM UPGRADE AUTHORITY** | a **Squads config transaction**, at `app.squads.so` | `turf-vault/scripts/squad.json` → `members.alex_bot` |
| `scripts/squad-upgrade.js`, which signs upgrades as `ALEX_BOT_KEY` | supplied per run from 1Password, not a stored config var | `squad-upgrade.js:86` `loadKey("ALEX_BOT_KEY")` |

**`update_signers` does not touch Squads membership.** They are separate systems
that happen to share a pubkey: one is turf-vault's own in-program multisig, the
other is the Squads V4 multisig that owns the program's upgrade authority. Rotate
the first and stop, and the rotated-out key still holds **upgrade authority over
the mainnet program** — a strictly larger power than the one you just took away.

The Squads half is mutable and is an operator act at `app.squads.so`. The mechanism,
inline so you need not leave this file: propose **one** config transaction doing
`removeMember(<old pubkey>)` + `addMember(<new pubkey>, Permissions.all())`, keep
threshold 2, approve with the **two clean members** (never with the key being
rotated out), execute.

**Name the permission mask, and make it 7.** `addMember` is not symmetric with
`removeMember`: remove takes a bare pubkey, add takes a `Member { key, permissions:
{ mask: u8 } }`, so a mask is ALWAYS chosen — by you, or by whatever the Squads UI
had checked when you were not looking. Which bits this key needs is decided by
`turf-vault/scripts/squad-upgrade.js`, the only thing that signs upgrades, and it
uses all three:

| Bit | Value | Where `squad-upgrade.js` needs it |
|---|---|---|
| `Initiate` | 1 | `:155` `vaultTransactionCreate({ creator: alexBot })` and `:158` `proposalCreate({ creator: alexBot })` |
| `Vote` | 2 | `:161` `proposalApprove({ member: alexBot })` |
| `Execute` | 4 | `:172` `vaultTransactionExecute({ member: alexBot })` |

`Initiate | Vote | Execute` = **mask 7** = `Permissions.all()`. The bit values are
`@sqds/multisig`'s own (`Permission.Initiate = 0b001`, `Vote = 0b010`,
`Execute = 0b100`), measured against 2.1.4, the version turf-vault pins. Grant
anything narrower and the rotation still "succeeds" — the break lands at the NEXT
upgrade, in whichever call lost its bit, weeks later and far from this SOP.

Grant 7 because the tooling provably needs 7, **not** because the other two members
happen to hold it. Those are different claims, and only the first one survives a
change to the script: if `squad-upgrade.js` ever stops approving as Alex Bot, or
splits create from execute across two keys, recompute this table and grant the
narrower mask then. A rotation is the wrong moment to also re-scope authority — do
one thing, so a later failure has one candidate cause.

**There is no ConfigAction that edits an existing member's permissions.** The seven
variants are add member, remove member, change threshold, set timelock, add spending
limit, remove spending limit, set rent collector. A wrong mask is repaired only by
another `removeMember` + `addMember` — another config transaction, another two-human
ceremony at `app.squads.so`. That cost is why step 5 below reads the mask back
instead of trusting the checkboxes you clicked.

**One transaction, not two.** Executing any config transaction sets the multisig's
`stale_transaction_index` to the current `transaction_index`, invalidating every
proposal created before it. Split the rotation and execute the remove first, and the
pending add is STALE — it fails at execute with `StaleProposal` (`0x1777`, 6007) and
must be re-proposed and re-approved. You are meanwhile sitting at **2 members,
threshold 2**: a 2-of-2 over mainnet upgrade authority, where losing either surviving
key is unrecoverable. One transaction and the multisig never leaves three members.
The same staleness kills any upgrade proposal already in flight — land or abandon
those before you rotate.

`turf-vault/docs/KEY_ROTATION.md` §7 describes the same mechanism, and
`secrets-rotation.md` is right that the file as a whole is a **SUPERSEDED plan** —
so take the mechanism from it and **no addresses**: its program IDs, multisig PDAs
and member lists are historical.

**What is live truth for what.** `turf-vault/scripts/squad.json`'s top level is
authoritative for the ADDRESSES, because it is what `squad-upgrade.js` actually
reads — take `multisigPda` from there. It is **not** authoritative for membership:
its own `_comment` says "members is documentation only", and no Squads rotation
writes to a committed file. Live truth for **members, their masks, and the
threshold** is the on-chain `Multisig` account at `multisigPda` — the read
`squad-upgrade.js:143` already performs, and the one step 5 below runs.

`solana program show <PROGRAM_ID> --url mainnet-beta` does **not** confirm a member
rotation and must never be used as its proof. It prints the upgrade AUTHORITY, which
is the Squads vault PDA — the same value before and after, because rotating a member
changes who can DIRECT that PDA, not the PDA itself. It returns the answer you were
hoping for whether or not the rotation happened. Run it for the question it does
answer — that upgrade authority is still the Squads vault at all, and has not been
moved or revoked — and read membership off the `Multisig` account.

Now the on-chain signer half. Read the program, not the intuition
(`turf-vault/programs/turf_vault/src/instructions/update_signers.rs`, and
`validate_multisig` at `programs/turf_vault/src/state.rs:159`):

- `update_signers(new_signers: [Pubkey; 3])` does `vault.signers = new_signers` — a
  **whole-set replace across three fixed slots**. There is no fourth slot, so every
  legal rotation EVICTS somebody.
- Auth is 2-of-3 of the CURRENT signers: `validate_multisig` is `s1 != s2 &&
  is_signer(s1) && is_signer(s2)` — two DISTINCT current signers must sign.
- Signer continuity (OPSEC-027) requires **both** cosigners who authorized THIS
  update to survive it. It is enforced by the program, not by policy —
  `SignerContinuityRequired` (6017). So the evictable slot is exactly the one that
  did NOT cosign — WHO you may evict is decided by who shows up to sign, and there
  are three legal rotations, one per choice of cosigning pair.
- The set must also contain no duplicates and no `Pubkey::default()`.

> **The key you are rotating out must not supply either signature.** Alex Bot is
> the SERVER key that normally partial-signs as `admin`, so the tooling and the
> instinct both point at it — and continuity then requires it to SURVIVE the
> update it authorized. Two outcomes, and the second is the dangerous one: the
> eviction trips 6017 and fails loudly, **or** it succeeds having evicted the only
> other slot — a signer who did nothing wrong — and left the compromised key in
> place. You would read that transaction as a completed rotation. Both humans
> cosign an eviction (Alex + Mason from Phantom); the compromised key stays out of
> it. Same rule at Squads: approve the config transaction with the two clean
> members, never with the member being removed.

**There is no overlap window in `VaultState`, and that is by construction.**
(The Squads membership above is a different system with its own rules.) Because
the instruction replaces the whole set across three fixed slots, the new pubkey
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

1. Mint the new keypair, **and fund it**. Nothing is live yet, and an unfunded
   key is not a working replacement: Alex Bot is the FEE PAYER, not just an
   identity. It pays all five transactions in `squad-upgrade.js` — including
   Mason's approval (`:164`) — signs and pays the permissionless `extendProgram`
   (`:119`, `:123`), and is the payer slot for `create_contest`,
   `mint_entry_token` and `enter_contest` (`turf-monster/docs/SOLANA.md`, "Two-level
   multisig auth"). Skip this and every one of those fails AFTER the rotation reads
   as done — the same late, far-from-here failure as a wrong permission mask.
   `turf-vault/docs/KEY_ROTATION.md` §2 is the recipe: read the old key's balance
   and transfer it across, less dust. Take the MOVE from it, not its `4.55` — that
   figure is sized for the v0.20 migration, which front-loaded ~3.5 SOL of one-time
   ProgramData rent for a NEW program deploy (`KEY_ROTATION.md:341`, `:347`). A
   rotation onto an already-deployed program owes no such rent. **If the old key is
   COMPROMISED, do not plan on sweeping it** — whoever holds it can drain it first.
   Fund the new key from a key you control, and treat any balance still there as a
   bonus.
2. Update registration **one of two**: run `update_signers` with the new pubkey in
   the evicted slot, cosigned by the two who stay — **not** by the key being
   evicted (the callout above; it either trips 6017 or evicts the wrong slot).
   **There is no operational script for this** — `update_signers` appears in
   `turf-vault/tests/turf_vault.ts` and nowhere in `scripts/`. Budget for writing
   the transaction and for two humans at Phantom.
3. VERIFY it: read `VaultState` (`seeds = [b"vault"]`) back and confirm the new
   pubkey is in `signers` **and the old one is not** — and that both human
   cosigners survived. "The transaction succeeded" does not distinguish the
   rotation you wanted from the one that evicted the wrong slot.
4. Update registration **two of two — the Squads membership**: propose ONE config
   transaction doing `removeMember(old)` + `addMember(new, Permissions.all())` at
   `app.squads.so` against the live `multisigPda` in `scripts/squad.json`, threshold
   stays 2, approved by the two clean members. **Mask 7 — see the table above; the
   UI will happily give you a narrower one.** This step does **not** move program
   upgrade authority: that authority is the Squads vault PDA before and after, and
   is unchanged by a membership edit. What it moves is **who can direct it** — which
   is the whole of the power, and is a separate 2-of-3 on a separate system that
   step 2 does not touch and cannot.
5. VERIFY it — with the block under **Verifying the Squads rotation** below, not by
   eye. Four properties, and the member list shows only two of them: three members,
   threshold 2, the new pubkey present **with mask 7**, the old pubkey gone. A
   verification that stops at "the right pubkeys are listed" passes over a member
   who cannot execute, and the first thing that tells you is a failed upgrade.
6. ONLY THEN set the config var on each consuming app.
7. Phase 6. For this credential the on-chain eviction already happened at step 2
   and the Squads eviction at step 4, so Phase 6 clears the dead secret out of the
   remaining stores — Heroku, `.env`, 1Password, and any shell that ran
   `squad-upgrade.js`. **Do not read that as "nothing else holds authority": read
   it off your Phase 1 list, which is why the list is the rotation.**

#### Verifying the Squads rotation

Step 5's four properties, graded against the on-chain `Multisig` account. The
reader is separate from the grader on purpose: the read is the part that talks to
mainnet, the grading is the part that must be able to FAIL, and only the second one
is worth testing.

```bash
# The reader. Live truth for members, masks and threshold — NOT squad.json.
# Prints "threshold <n>", then one "<pubkey> <mask>" line per member.
squads_members() {
  ( cd /Users/alex/projects/turf-vault && node -e "
      const multisig = require(\"@sqds/multisig\");
      const { Connection, PublicKey } = require(\"@solana/web3.js\");
      const cfg = require(\"./scripts/squad.json\");
      const rpc = process.env.RPC_URL || \"https://api.mainnet-beta.solana.com\";
      (async () => {
        const ms = await multisig.accounts.Multisig.fromAccountAddress(
          new Connection(rpc), new PublicKey(cfg.multisigPda));
        console.log(\"threshold \" + ms.threshold);
        for (const m of ms.members) {
          console.log(m.key.toBase58() + \" \" + m.permissions.mask);
        }
      })().catch((e) => { console.error(e.message); process.exit(1); });
  " )
}
```

```bash
# The grader. Substitute the two pubkeys, then run it. It prints one FAIL line per
# broken property and exits non-zero; a silent PASS is the only success.
NEW_MEMBER=<new pubkey>
OLD_MEMBER=<old pubkey>
WANT_MASK=7

check_squads_rotation() {
  local ms
  local bad=0
  local threshold count new_mask old_hit

  ms=$(squads_members) || {
    printf 'FAIL  could not read the Multisig account — this verification is VOID\n' >&2
    return 1
  }

  threshold=$(printf '%s\n' "$ms" | awk '$1=="threshold" {print $2}')
  count=$(printf '%s\n' "$ms" | awk '$1!="threshold"' | wc -l | tr -d ' ')
  new_mask=$(printf '%s\n' "$ms" | awk -v k="$NEW_MEMBER" '$1==k {print $2}')
  old_hit=$(printf '%s\n' "$ms" | awk -v k="$OLD_MEMBER" '$1==k {print $1}')

  [ "$count" = 3 ] || { printf 'FAIL  %s members, expected 3\n' "$count"; bad=1; }
  [ "$threshold" = 2 ] || { printf 'FAIL  threshold %s, expected 2\n' "$threshold"; bad=1; }
  [ -z "$old_hit" ] || { printf 'FAIL  the rotated-out key is STILL a member\n'; bad=1; }
  [ -n "$new_mask" ] || { printf 'FAIL  the new key is NOT a member\n'; bad=1; }
  [ "$new_mask" = "$WANT_MASK" ] || {
    printf 'FAIL  new member mask is %s, expected %s (Initiate|Vote|Execute). squad-upgrade.js will break at the NEXT upgrade, not now.\n' "${new_mask:-none}" "$WANT_MASK"
    bad=1
  }

  [ "$bad" = 0 ] && printf 'PASS  3 members, threshold 2, new key present with mask %s, old key gone\n' "$WANT_MASK"
  return "$bad"
}

check_squads_rotation
```

A FAIL on the mask is recoverable **right now**, while both humans are still at
their wallets, by re-running step 4 with the correct mask. Discovered at the next
upgrade instead, it is the same two-human ceremony scheduled from cold — which is
the entire reason this reads the mask rather than the member list.


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
3. Update **every** registration of the public half, and PROVE each is accepted.
   There may be more than one, on unrelated systems — the worked example has two,
   and updating only the first leaves real authority with the old key.
4. Write the runtime stores: Heroku per app, GitHub Actions and Dependabot, `.env`
   and desks.
5. Migrate or retire the data (Phase 2's answer).
6. Verify liveness store by store.
7. Retire the old value at the source. **Point of no return.**

**Read the Rollback section below before you execute step 1.** It is short, and
knowing where the door closes is what lets you move quickly up to that point.

---

## Phase 4 — Execute

> **Every step of Phase 4 writes `$NEW` into a store. An empty `$NEW` does not
> fail — it succeeds, and empties the store.** That is the single most destructive
> thing this SOP can do, and it is silent: `heroku config:set "<VAR>="` exits 0,
> and a `.env` rewritten to a bare `<VAR>=` looks like a well-formed file.

One shell owns `$NEW` — **this one**, the shell that runs Phases 4 and 5 — and it
holds it from 4.1 until Phase 6 unsets it. Before running anything else in this
phase, prove the shell has it:

```bash
: "${NEW:?NEW is not set — go back to 4.1. Running Phase 4 now would write an empty value to every store.}"
printf '%s' "$NEW" | digest    # a digest, not EMPTY, and it matches what you minted
```

Every write below repeats that guard, because the blocks get copy-pasted one at a
time and a guard that lives only at the top of the section is not there when you
need it. **Each guard is chained to its write with `&&`, and that is
load-bearing, not style.** An unset `${NEW:?...}` aborts a SCRIPT, but an
interactive shell — the one you are pasting into — prints the refusal and carries
straight on to the next line. Measured 2026-09-09 in both `zsh -i` and `bash -i`:
the guard on its own line refused, and the loop under it still stripped every
fixture `.env` to a bare `<VAR>=`. `&&` makes the guard and the write ONE command,
so the refusal actually skips the write in every shell.

### 4.1 Mint, and put the value in `$NEW`

Mint at the provider, by its own recipe. Then get it into `$NEW` **in the shell
that will run the rest of Phase 4** — this is the assignment the rest of the
procedure depends on, and there is no other:

```bash
read -rs NEW     # paste the value; the screen stays blank
                 # -r because a backslash in a token must survive the read;
                 # without it, read corrupts the value silently
printf '%s' "$NEW" | digest    # non-EMPTY, and matches the provider's copy
```

**If the value starts in Mr. McRitchie's hands**, `credential-filing` §5 has him
`read -rs T` in HIS terminal. That is a different shell, and `$NEW` is empty in
yours. Pick one of exactly two shapes and say which you picked, out loud:

- **He runs Phases 4 and 5** in his terminal, and the SOP's `$NEW` is his `$T` —
  substitute it once, at the top, not per command.
- **He hands the value across** into the rotating shell with its own `read -rs NEW`
  (never through chat, a file, or an argument), and `unset T` only after 4.2's
  read-back matches.

What must not happen is Phase 4 running in a shell that never received the value.
That shell's `$NEW` is empty, every guard below is what stops it, and without them
it writes `<VAR>=` to ten apps and fifty-seven desk `.env` files in under a minute.

### 4.2 File it in 1Password FIRST

Before any consumer depends on it. The item already exists (this SOP replaces a
value; `credential-filing` creates), so this is an **edit**, and it needs the lane
that may WRITE the vault — `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` for `studio-agents*`
(`credential-filing` §4); an agent-lane token fails with `(101) You do not have
permission`:

```bash
: "${NEW:?refusing to file an empty value}" && op item edit "<item>" --vault <vault> "<field>[concealed]=$NEW"
```

Update `authorization-id`, `used-by`, and the `scope`/`CAN`/`CANNOT` notes in the
same edit if the new credential's scope differs — a permission matrix describing
the previous key is worse than none. That is more `op item edit` assignments on the
same call: `"authorization-id[text]=<new id>"`, `"notesPlain=scope: …"`.

Then read it back by digest:

```bash
op item get "<item>" --vault <vault> --fields label="<field>" --reveal | digest
printf '%s' "$NEW" | digest      # the two must match, and NEITHER may print EMPTY
```

Whoever held the source value runs the comparison; if that is Mr. McRitchie, he
runs both lines in his terminal against his `$T` and `unset T` only after they
match. A shell that has already forgotten the value digests nothing — which the
helper refuses, rather than reporting a match against an empty vault field.

**Overwriting a 1Password field is reversible** — the item keeps version history.
That is why this store goes first.

### 4.3 Update every registration, and prove each is accepted

Only if Phase 2 said a public half is registered — and then once **per row of your
Phase 1 list**, not once. Two registrations of the same pubkey on two systems are
two updates with two proofs; the worked example above is exactly that shape, and
the second one carries program upgrade authority.

For each: do the update, then make the system that must accept the new identity
actually accept it — read the on-chain account back, send one signed request the
far side verifies, fire one test webhook. A registration that "looks updated" in a
dashboard is not a proof.

### 4.4 Write the runtime stores

**Heroku, per app.** From the shell variable, so the value never appears in the
command you type — and behind the guard, so an empty `$NEW` refuses instead of
blanking the variable on every app in the list. **Not for
`MANAGED_WALLET_ENCRYPTION_KEY`:** this loop sets the new key alone and strands every
existing wallet. That key is written by §2.1 step 5 — both variables, one
command.

```bash
: "${NEW:?refusing to write — NEW is empty and this would blank <VAR> on every app}" &&
APPS="${APPS:?set APPS to the apps from your Phase 1 list, space separated}" &&
for app in $APPS; do
  heroku config:set "<VAR>=$NEW" --app "$app"
done
```

Read the loop's output before going on: a `config:set` that failed leaves that app
on the old value, and the sweep in Phase 5 is what catches it. **Only once every
app reported success**, stamp the moment — the snapshot step below uses it to tell
a pre-rotation snapshot from a post-rotation one, so a stamp taken early marks a
stale snapshot as fresh and keeps the dead value:

```bash
ROTATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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

**`.env` on desks.** Untouched by that, and there are dozens (57 files, measured
2026-09-09). Finished desks are better reclaimed than rewritten — that is
[`clean-infra`](clean-infra.md). Desks that must keep running get the one line
replaced, printing nothing:

```bash
: "${NEW:?refusing to write — NEW is empty and this would strip <VAR> out of every desk .env}" &&
for f in /Users/alex/projects/*/.worktrees/*/.env; do
  [ -f "$f" ] || continue
  grep -q '^<VAR>=' "$f" || continue
  tmp=$(mktemp); grep -v '^<VAR>=' "$f" > "$tmp"; printf '<VAR>=%s\n' "$NEW" >> "$tmp"
  mv "$tmp" "$f"; chmod 600 "$f"
done
```

Without that first line this loop is the most destructive command in the SOP: it
finds every desk holding the credential and replaces the live value with nothing,
leaving a bare `<VAR>=` that reads as a well-formed file. It writes the value
UNQUOTED; if the credential contains a space, a `#`, or a quote, quote it in the
`printf` to match how the rest of that `.env` is written.

**Env snapshots.** `bin/ecosystem-build` Phase 9 writes today's snapshot, so the
naive `rm -f …env-snapshot-*.json` deletes the fresh post-rotation fallback you
just made along with the stale ones. Split them on the `captured_at` stamp inside
each file instead, which is exact where the filename's date is not:

```bash
: "${ROTATED_AT:?stamp ROTATED_AT above, when the Heroku writes finished}" &&
for snap in /Users/alex/projects/mcritchie-studio/tmp/env-snapshot-*.json; do
  [ -f "$snap" ] || continue
  cap=$(jq -r '.captured_at // empty' "$snap")
  if [ -n "$cap" ] && [[ "$cap" > "$ROTATED_AT" ]]; then
    printf 'KEEP   %s (captured %s — written after the rotation)\n' "$snap" "$cap"
  else
    printf 'DELETE %s (captured %s — holds the dead value)\n' "$snap" "${cap:-unknown}"
    rm -f "$snap"
  fi
done
```

Run `bin/ecosystem-build` FIRST (above), so a post-rotation snapshot exists to
keep. **This `rm` is irreversible and it is the one step in Phase 4 that is** —
see the Phase 6 headline. If you would rather keep the stale snapshots, skip the
loop and record in the receipt that you kept them and why.

### 4.5 Migrate the data

Phase 2's answer, executed now — the re-encryption, or the announced invalidation.
Do it before Phase 6: every migration in Phase 2 needs the OLD value to still work.
For `MANAGED_WALLET_ENCRYPTION_KEY` this is §2.1 step 6.

---

## Phase 5 — Verify liveness, store by store

Liveness means **the new value is the one in use**, proved by something only the
new credential could produce. Absence of an error is not that.

> **A digest match is only evidence when both sides are non-empty.** Two empty
> values match. A read that failed matches a store that was wiped, and the pair
> reports MATCH — which is exactly what Phase 4 produces if it ran with an empty
> `$NEW`. So Phase 5 opens by proving the reference side is real, and every
> comparison below goes through `digest`, which refuses to certify nothing:

```bash
printf '%s' "$NEW" | digest    # EMPTY here means Phase 5 can prove nothing.
                               # Stop. Do not compare, do not proceed to Phase 6.
```

If any store's read prints `EMPTY`, that store is **not verified** — it is either
unset, blanked by this rotation, or unreadable, and those are three different next
moves. Never re-run the comparison with a bare `shasum` to get a digest out of it.

| Store | The proof |
|---|---|
| 1Password | filed field's `digest` == `$NEW`'s `digest`, neither EMPTY |
| Heroku, per app | `jq -r '.["<VAR>"] // empty' \| digest` == `$NEW`'s `digest`, neither EMPTY, AND an authenticated call from a dyno: `heroku run --exit-code --app <app> bin/rails runner '<one call only the new credential can make>'` |
| GitHub Actions | re-run the workflow that consumes it and read the run's conclusion — plus confirm the step that uses it actually ran |
| GitHub Dependabot | the Dependabot tab shows the secret updated today, and the next Dependabot PR's `consumer-ci` run is green |
| `.env` / desks | per-file `digest` match, from the sweep in Phase 1.2, none EMPTY |
| Registration | one signed request the far side ACCEPTS, or the account read back on-chain |
| Managed-wallet ciphertexts | `heroku run --exit-code --app <app> bin/rails solana:verify_managed_wallet_keys` prints `still-previous-key: 0` and `VERIFIED -- T of T`, with T equal to §2.1 Gate 0's second count run again; AND the running app opens a wallet: `heroku run --exit-code --app <app> bin/rails runner 'u = User.where.not(encrypted_web2_solana_private_key: [nil, ""]).first; puts u.solana_keypair.to_base58 == u.web2_solana_address'` prints `true` |

The digest match proves the store holds the value you minted. It does **not** prove
the running process uses it — that is what the second column of the Heroku row is
for, and why every registration is proved by an acceptance rather than a read.

### What does NOT count as verification

- **A green deploy.** `bin/release.rb`'s post-deploy check derives its verdict
  solely from `heroku run --exit-code`'s status and never parses the output. Green
  proves exit 0 and nothing else.
- **`heroku config:get` returning something.** Banned above: it prints the same
  bare newline for an absent key and an empty one, so "it returned" distinguishes
  nothing you need distinguished.
- **An empty `heroku config` read.** Measured 2026-09-09: the failure IS loud — an
  invalid token prints `Error: The token provided to HEROKU_API_KEY is invalid` and
  exits 1, an absent one prompts for a browser login and exits 1. What makes it
  dangerous is that **stdout is 0 bytes in both cases**, and a pipeline throws away
  the stderr and reports `jq`'s exit status instead of `heroku`'s. So the read still
  arrives at your comparison as an empty value that digests like a wiped one. Read
  the control (`jq 'length'`) first, and let `digest` refuse the EMPTY.
  (`HEROKU_API_KEY` is **not** sanitized in an agent shell — measured present, so a
  read that comes back empty is more likely a bad key than a missing one.)
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

**One exception, and it is in Phase 4, not here:** the env-snapshot `rm` in 4.4
destroys the Heroku-independent fallback for every snapshot it deletes, and no
history brings those back. Nothing else before this point is like that — the
1Password field keeps version history, a config var can be re-set from the old
value while you still hold it, a `.env` line can be rewritten, and the on-chain
eviction at 4.3 is reversible **by construction**: signer continuity requires both
authorizing cosigners to survive the update, so two known-good keys can always
cosign the reversal. Reversible is not free — the reversal is another 2-of-3 with
two humans at Phantom — but it is a door, and this one is not.

Do it only when Phase 5 passed for EVERY store on the Phase 1 list. Where the
credential was migrated rather than replaced (Phase 2), give it 24-48 hours of
confirmed normal operation first.

| Source | Revoke with |
|---|---|
| Heroku authorization | **operator step.** `heroku authorizations` fails under the agent lane — measured 2026-09-09: `Error: The scope of this OAuth authorization does not allow access to this resource.` Mr. McRitchie revokes at https://dashboard.heroku.com/account/applications, matching the row by its **description**, which is the only human-readable handle an authorization has. Never revoke the one the current session is authenticating with; if you cannot tell them apart, mint the replacement first, prove it works, and revoke the row that is then unused. |
| AWS access key | delete the old access key for that IAM user in the console or CLI |
| Provider API key | the provider's console — "revoke", not "hide" |
| On-chain signer (`VaultState`) | **already done in 4.3** — the whole-set `update_signers` evicted the old pubkey in the same transaction. There is no second eviction. Reversible only by another 2-of-3 `update_signers`, so keep the old secret filed until Phase 5 passes. |
| Squads membership (upgrade authority) | **a SEPARATE eviction, also in 4.3** — `update_signers` does not touch it. If your Phase 1 list has a Squads row and 4.3 did not clear it, the old key still holds upgrade authority and Phase 6 has not retired it. |
| 1Password field | already overwritten in 4.2 — **still recoverable via item history**, so this is not the point of no return |
| `MANAGED_WALLET_ENCRYPTION_KEY` (the old value) | after Phase 5 passed AND 24-48 hours of normal operation: `heroku config:unset MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS --app <app>`, then the verifier again — it must still read `VERIFIED -- T of T`, now with no old key to lean on. Keep the `previous encryption key` field for as long as a pre-rotation Postgres backup could be restored: a restored backup brings back rows sealed under the old key, and the only way back from that is this procedure again, with the old key as `…_PREVIOUS`. |

Then clear the shell: `unset NEW` (and `unset T` if Mr. McRitchie still holds one).

---

## Rollback

**Before Phase 6 there is a real rollback**, because the old credential still
works. Walk Phase 4 backwards: put the old value back in the runtime stores first
(Heroku, GitHub, `.env`), then revert EVERY registration you moved, then restore
the 1Password
field from item history. Re-run Phase 5 against the old value. Then stop and work
out what failed before trying again.

**After Phase 6 there is none.** The path is forward only: mint again, and treat
it as an incident — a revoked credential with no working replacement is an outage,
and the clock is running.

The half-done shapes, and the way out of each:

| Symptom | What happened | Do this |
|---|---|---|
| One app 401s, the rest are fine | a `config:set` was missed | re-run the ten-app `has("<VAR>")` sweep from 1.2; `digest`-compare each |
| Everything is fine until a Dependabot PR | Actions updated, Dependabot not | operator updates the Dependabot tab |
| The app authenticates but the far side rejects it | config moved before the registration | put the OLD value back on the app, finish Phase 4.3, then re-flip |
| The app boots but cannot read credentials | new `RAILS_MASTER_KEY` against old ciphertext | restore the old key; redo Phase 2's re-encryption so key and `.enc` deploy together |
| A desk fails while production is healthy | a stale desk `.env` | re-run the desk loop in 4.4, or reclaim the desk |
| Every managed-wallet read fails right after the config write | the new key went live without `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS`, or with a value that is not the live old key | one `config:set` of `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD`, keeping the new key. No row has been re-sealed yet, so every read comes back. Then rehearse again (§2.1 step 3). Never remove the new key: wallets minted since the write are sealed under it. |
| The managed-wallet migration prints `NOT COMPLETE` | a row failed its read-back or changed mid-run | nothing to undo: every row is whole, and both keys are still configured. Read the `FAILED` lines, re-run, and keep the old key until the verifier reads `VERIFIED`. |
| You want to abandon a managed-wallet rotation | — | swap the roles in ONE command (`MANAGED_WALLET_ENCRYPTION_KEY=$OLD`, `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$NEW`) and run the migration: it re-seals every row back under the old key. Unset `…_PREVIOUS` only once the verifier reads `VERIFIED -- T of T`. |
| Nothing works and the old value is gone | Phase 6 ran before Phase 5 passed | forward only — mint again; this is why Phase 6 is last |
| Every store reads `<VAR>=` and Phase 5 said MATCH | Phase 4 ran with an empty `$NEW`, and two empty values digest alike | you still hold the OLD value (Phase 6 has not run): put it back everywhere from the Phase 1 list, then restart 4.1 with the guards. If Phase 6 HAS run, this is an outage — mint again. |

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
  `SOLANA_ADMIN_KEY`, Anthropic, X). They are accelerators for a specific secret;
  this SOP is the procedure, and where the two disagree, this file wins and the
  recipe gets fixed in the same pass — as its `MANAGED_WALLET_ENCRYPTION_KEY` and
  `SOLANA_ADMIN_KEY` sections were on 2026-09-09. Precedence is not a substitute
  for sweeping: a recipe that contradicts this SOP is a defect in that file, and
  leaving it in place because "the SOP wins" is how the next reader follows it.
- `docs/agents/modules/credentials.md` — the access contract and the two 1Password
  lanes.
- `docs/agents/modules/credential-inventory.md` §"Shared AWS identity" — what
  sharing one IAM user across four brands costs at rotation time.
- `turf-monster/docs/SOLANA.md` — the signer set, the Squads upgrade authority, and
  the `config:get` ban in its original context.
