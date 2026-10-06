# Credential Rotation SOP (Steffon)

## Status: Active

**When it runs:** one credential is compromised, stale, or due, and must go from
"this value is suspect" to "the new value is live everywhere and the old one is
dead." Run it top to bottom, once per credential. Phase 1 may cover a set; never
merge two credentials' Phase 4. Filing a NEW credential is
[`credential-filing`](credential-filing.md); this SOP replaces a value that is
already filed. A real exposure of money, customer data, production or a public
leak rotates here first; anything lesser is triaged in
[`credential-issues`](../../../modules/credential-issues.md).

**Precondition: the admin lane.** Vault writes and `studio-agents-admin` reads run
on `OP_ADMIN_SERVICE_ACCOUNT_TOKEN`. `source ~/.zprofile.admin` (never through a
pipe: the token lands in a subshell that exits). If the machine has no such file,
Alex runs `bin/setup-1pass-token --admin` once.

**Placeholders.** `<VAR>` is the environment-variable name (`SOLANA_ADMIN_KEY`);
`<item>`, `<field>`, `<vault>` name the 1Password home; `<app>`, `<file>`, `<repo>`,
`<env>` name one target. Substitute every one before running. `$NEW`, `$OLD`,
`$APPS` and `$ROTATED_AT` are shell variables this SOP assigns; leave them as written.

## Never print the value

Not in a terminal, transcript, task, PR, commit, log, Discord post or report.
List key NAMES (`heroku config --json --app <app> | jq -r 'keys[]'`), print file
names (`grep -rl`), hold the value in one shell variable, `unset` it at the end.
A digest is for the shell only: the repo is public, and a digest of a live
secret confirms a guess. A pushed value stays fetchable by SHA after a force-push;
a GitHub Support purge is Alex's call.

### Compare by digest — and a digest of nothing is not a comparison

Two values match when their digests match, and two EMPTY values match too:
`sha256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
An unset var, a stripped `.env` line and a failed read all produce it. Every
comparison goes through this helper, which refuses empty input. Paste it into
the shell that runs Phases 4 and 5:

```bash
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

```bash
op item get "<item>" --vault <vault> --fields label="<field>" --reveal | digest   # the vault
printf '%s' "$NEW" | digest                                                      # what you minted
heroku config --json --app <app> | jq -r '.["<VAR>"] // empty' | digest           # an app
grep -m1 '^<VAR>=' <file> | sed -E 's/^[^=]+=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' | digest   # a .env
```

EMPTY is the answer: stop, never fall back to a bare `shasum`. `heroku config:get`
is banned (an absent key and an empty one print the same newline); ask presence
with `heroku config --json --app <app> | jq 'has("<VAR>")'`. A failed Heroku read
prints nothing on stdout, so prove auth first: `heroku auth:whoami` (expect
alex@mcritchie.studio) and `heroku config --json --app <app> | jq 'length'` (0 means
the read failed).

## Phase 1 — Enumerate every store

Write one line per store before minting: where, who writes it, value or public
half. The list is the rotation; every later phase walks it.

| Store | How to ask | Who writes it |
|---|---|---|
| 1Password item + field | `op item list --vault <vault> --format json \| jq -r '.[].title'` | the vault's writing lane (`credential-filing` §4) |
| Heroku config, every app | the fleet sweep below | any lane with a Heroku key |
| GitHub Actions secrets, repo and environment | `gh secret list -R McRitchie-Studio/<repo>` (`--env <env>`) | the admin lane, `github.mcritchie-admin` |
| GitHub Dependabot secrets | `gh secret list --app dependabot -R McRitchie-Studio/<repo>` | Alex only |
| `.env` on primaries and every desk | `grep -rl '^<VAR>=' /Users/alex/projects/*/.env /Users/alex/projects/*/.worktrees/*/.env` | you |
| Env snapshots | `ls -l /Users/alex/projects/mcritchie-studio/tmp/env-snapshot-*.json` | you (delete or knowingly keep) |
| The public half | on-chain account, provider dashboard, webhook config | often a third party: the long pole |

```bash
heroku auth:whoami
for app in $(heroku apps --all --json | jq -r '.[].name'); do
  printf '%-26s keys=%-4s has=%s\n' "$app" \
    "$(heroku config --json --app "$app" | jq 'length')" \
    "$(heroku config --json --app "$app" | jq 'has("<VAR>")')"
done
```

`keys=0` means that read failed. A lane sees only its own 1Password vaults, so
absence from `op vault list` is a lane gap, not a missing vault; on `(101)` check
`op service-account ratelimit` first. Actions and Dependabot are separate stores:
`studio-engine`'s `consumer-ci.yml` consumes `MCRITCHIE_AGENT_APP_ID` and
`MCRITCHIE_AGENT_PRIVATE_KEY`, and a Dependabot PR runs it with the Dependabot copy.
The admin lane writes Actions secrets with the value on stdin:

```bash
source ~/.zprofile.admin                       # without a pipe
export GH_TOKEN="$(GH_APP_ITEM=github.mcritchie-admin /Users/alex/projects/mcritchie-studio/bin/gh-token)"
: "${NEW:?refusing to set an empty value}" && \
  printf '%s' "$NEW" | gh secret set <VAR> --env <env> -R McRitchie-Studio/<repo>
gh api repos/McRitchie-Studio/<repo>/environments/<env>/secrets/<VAR> --jq .updated_at   # moved to now
```

**The hub's CI `HEROKU_API_KEY` is scripted:** `bin/rotate-heroku-ci-key --dry-run`,
then without the flag. It mints with `HEROKU_STUDIO_ADMIN_API_KEY`, files
`heroku.studio.applications` in `studio-applications`, sets the `qa` and
`production` environment secrets, proves each with a no-op deploy dispatch,
revokes the old authorization, and rolls back on a failed proof. Afterwards
refresh `HEROKU_STUDIO_APPLICATIONS_API_KEY` in `~/.zprofile.admin`.

`bin/agent-worktree` copies the primary `.env` into each desk, and
`bin/ecosystem-build` refreshes primaries only, so desks hold stale copies. Its
env snapshots hold every primary's `.env`, stamped `captured_at`.

## Phase 2 — The data question

What did the old value authenticate or ENCRYPT, and does that survive the change?

| Answer | Example | Cost |
|---|---|---|
| Nothing survives; it only authenticated | an API key, `HEROKU_API_KEY` | none |
| An artefact is re-encrypted | `RAILS_MASTER_KEY` | a re-encryption with both keys at hand |
| An artefact is re-encrypted by deployed code | `MANAGED_WALLET_ENCRYPTION_KEY` | §2.1, which replaces 4.1 to 4.5 |
| An artefact dies | `SECRET_KEY_BASE` | an announced logout: sessions and magic links stop verifying |
| A public half is registered elsewhere | a Solana signing key, a webhook secret | Phase 3: the registration moves first |

**`RAILS_MASTER_KEY`:** open `config/credentials.yml.enc` with the current key
(`EDITOR='code --wait' bin/rails credentials:edit`), copy the plaintext to
`(umask 077; : > "$TMPDIR/creds.$$")`, delete the `.enc` and `config/master.key`,
re-run `credentials:edit`, paste back, commit the new `.enc`, `rm -f` the scratch
file (macOS has no `shred`; `rm -P` is a no-op). The new config var and new
ciphertext go live in one deploy, per app. `SECRET_KEY_BASE` is its own config
var on the production apps, so sessions survive.

The old value stays retrievable until any migration is verified, and a migration
the running release cannot perform means no rotation.

### 2.1 `MANAGED_WALLET_ENCRYPTION_KEY` — deploy first, then migrate

`MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS` opens old rows and never seals;
`solana:reencrypt_managed_wallets` re-seals and reads back; `solana:verify_managed_wallet_keys`
counts. **Gate 0, per app holding the key:** the code is RUNNING there.

```bash
heroku run --exit-code --app turf-monster-mainnet bin/rails solana:verify_managed_wallet_keys
heroku run --exit-code --app turf-monster-mainnet bin/rails runner \
  'puts User.where.not(encrypted_web2_solana_private_key: [nil, ""]).count'
```

`Unrecognized command` means stop. Pass only on `VERIFIED -- N of N row(s) open
under the current key alone.` with N equal to the second count. Write N down.

1. **Mint** (64 hex, never on screen):

```bash
NEW=$(ruby -e 'require "securerandom"; print SecureRandom.hex(32)')
printf '%s' "$NEW" | digest
```

2. **Hold the old value and prove it is live.** The digests match, neither EMPTY,
   and `$OLD` is 64 hex; otherwise stop and route to Jasper.

```bash
OLD=$(op item get agent.managed_wallet --vault studio-agents --fields label="encryption key" --reveal)
printf '%s' "$OLD" | digest
heroku config --json --app turf-monster-mainnet | jq -r '.["MANAGED_WALLET_ENCRYPTION_KEY"] // empty' | digest
[[ "$OLD" =~ ^[0-9a-fA-F]{64}$ ]] && echo "OLD: 64 hex" || echo "OLD: NOT 64 hex"
```

3. **Rehearse on a one-off dyno**, app config untouched. Pass only on header
   `ROTATION`, `total: N  would-migrate: N  already-new: 0  failed: 0`, last line
   `DRY RUN CLEAN`. Anything else: stop.

```bash
: "${NEW:?NEW is not set -- go back to step 1}" && : "${OLD:?OLD is not set -- go back to step 2}" &&
[ "$NEW" != "$OLD" ] &&
heroku run --exit-code --app turf-monster-mainnet \
  --env "DRY_RUN=1;MANAGED_WALLET_ENCRYPTION_KEY=$NEW;MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD" \
  bin/rails solana:reencrypt_managed_wallets
```

4. **File both** (replaces 4.2): add a `previous encryption key` field holding
   `$OLD` to `agent.managed_wallet` first, then replace `encryption key` with
   `$NEW`. Read both back by digest.
5. **Write the app in ONE command** (replaces 4.4). From here `$NEW` never leaves the app.

```bash
: "${NEW:?refusing -- NEW is empty}" && : "${OLD:?refusing -- OLD is empty}" &&
[ "$NEW" != "$OLD" ] &&
heroku config:set "MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD" \
  "MANAGED_WALLET_ENCRYPTION_KEY=$NEW" --app turf-monster-mainnet
```

6. **Migrate** (replaces 4.5). Complete only on `failed: 0` with migrated plus
   already-new equal to total, `Read-back: T of T`, and a last line `COMPLETE`.
   `NOT COMPLETE` is safe: read the `FAILED` lines and re-run.

```bash
heroku run --exit-code --app turf-monster-mainnet --env "DRY_RUN=1" bin/rails solana:reencrypt_managed_wallets
heroku run --exit-code --app turf-monster-mainnet bin/rails solana:reencrypt_managed_wallets
```

Rotation re-seals the envelope, never a wallet key: old ciphertext in any backup
still opens with the old key. A COMPROMISED key is an incident: rotate, move funds
to fresh wallets, destroy pre-rotation backups, escalate to Alex.

## Phase 3 — Order the moves

Rotate the REGISTRATION before the CONFIG; the app never holds a credential
nothing accepts. The order: (1) mint, (2) file in 1Password, (3) update every
registration and prove each accepts, (4) write the runtime stores, (5) migrate,
(6) verify every store, (7) revoke the old value: the point of no return. Where a
provider allows two live keys (`agent.aws`, IAM user `mcritchie-s3`), mint a second,
deploy and verify everywhere, then delete the first.

### Registered public halves: the Xan signing key

`agent.xan.solana` (`studio-agents-admin`, field `private key`, pubkey `8K81…`) is
`SOLANA_ADMIN_KEY` on `turf-monster-qa` and `turf-monster-mainnet`. Read each
registration live; they move independently.

| Where it is registered or consumed | Updated by | Verified by |
|---|---|---|
| turf-vault `VaultState.signers` | `update_signers`, cosigned by signers who stay | reading `VaultState` (`seeds = [b"vault"]`) |
| Squads V4 upgrade-authority multisig, one per cluster | one config transaction at `app.squads.so` | `check_squads_rotation` below, against `multisigPda` in `turf-vault/scripts/squad.json` |
| `scripts/squad-upgrade.js` devnet seat `xan` in `scripts/lib/squad-clusters.js` | a turf-vault PR to that seat's `pubkey`; the script refuses a key that does not derive to it | the bot key is read per `--send` run from `SQUAD_KEY_XAN`, filled from an admin-lane 1Password read; Alex's key (`7ZDJ…`) is a Phantom export with no filed item, and the script never signs as it |

**`update_signers`** replaces the whole set; on the deployed program that is three
slots at 2-of-3 (read the program's shape before planning). The cosigners who
authorize an update must survive it (`SignerContinuityRequired`, 6017), so **the
key being rotated out never signs**: it either trips 6017 or evicts an innocent
slot. The two who stay cosign from Phantom. There is no overlap window and no
script on the mainnet path; budget for writing the transaction. Fund the new key
first (it is a fee payer for `create_contest`, `mint_entry_token`, `enter_contest`);
never plan to sweep a compromised key. Verify `VaultState`: new pubkey in, old
out, both cosigners still present.

**Squads** is a separate authority `update_signers` never touches. Propose ONE
config transaction: `removeMember(<old pubkey>)` + `addMember(<new pubkey>, { mask: $WANT_MASK })`,
threshold unchanged, approved by clean members only. Two transactions stale the
second (`StaleProposal`, 6007) and drop a member; land or cancel every approved
upgrade proposal first, because a stale Approved vault transaction still executes.
No action edits a member's mask, so read it off the chain before proposing:

```bash
# Reuses squads_members() from "Verifying the Squads rotation" below.
OLD_MEMBER=<old pubkey>
BEFORE=$(squads_members) || BEFORE=
WANT_MASK=$(printf '%s\n' "$BEFORE" | awk -v k="$OLD_MEMBER" '$1==k { print $2 }')
: "${WANT_MASK:?the outgoing key is not a member of this multisig — read the Multisig account again before proposing anything}"
WANT_THRESHOLD=$(printf '%s\n' "$BEFORE" | awk '$1=="threshold" { print $2 }')
: "${WANT_THRESHOLD:?the read carried no threshold — read the Multisig account again before proposing anything}"
WANT_COUNT=$(printf '%s\n' "$BEFORE" | awk '$1!="threshold"' | wc -l | tr -d ' ')
printf 'grant the new key mask %s (what %s holds now)\n' "$WANT_MASK" "$OLD_MEMBER"
printf 'expect %s members at threshold %s after the rotation\n' "$WANT_COUNT" "$WANT_THRESHOLD"
```

Then: rotate `VaultState`, verify it; rotate Squads with
`addMember(<new pubkey>, { mask: $WANT_MASK })`, verify it below; open the
`squad-clusters.js` PR on devnet; ONLY THEN set the config var (Phase 4).
`solana program show` never proves a member rotation: it prints the vault PDA either way.

#### Verifying the Squads rotation

```bash
# The reader. Live truth for members, masks and threshold — NOT squad.json.
SQUADS_CLUSTER=<cluster>   # devnet or mainnet, no default
squads_members() {
  ( cd /Users/alex/projects/turf-vault && SQUADS_CLUSTER="$SQUADS_CLUSTER" node -e "
      const multisig = require(\"@sqds/multisig\");
      const { Connection, PublicKey } = require(\"@solana/web3.js\");
      const { resolveCluster } = require(\"./scripts/lib/squad-clusters\");
      (async () => {
        const c = resolveCluster(process.env.SQUADS_CLUSTER);
        const conn = new Connection(c.rpcUrl);
        if ((await conn.getGenesisHash()) !== c.genesisHash) {
          throw new Error(\"that RPC is not \" + c.cluster + \"; refusing to read\");
        }
        const ms = await multisig.accounts.Multisig.fromAccountAddress(conn, new PublicKey(c.multisigPda));
        console.log(\"threshold \" + ms.threshold);
        for (const m of ms.members) { console.log(m.key.toBase58() + \" \" + m.permissions.mask); }
      })().catch((e) => { console.error(e.message); process.exit(1); });
  " )
}
```

```bash
# The grader: one FAIL line per broken property; a PASS line is the only success.
NEW_MEMBER=<new pubkey>
: "${OLD_MEMBER:?set it in the mask step above}"
: "${WANT_MASK:?read it from the chain in the mask step above, before the outgoing key was removed}"
: "${WANT_COUNT:?read it from the chain in the mask step above, before the config transaction was proposed}"
: "${WANT_THRESHOLD:?read it from the chain in the mask step above, before the config transaction was proposed}"
check_squads_rotation() {
  local ms bad=0 threshold count new_mask old_hit
  ms=$(squads_members) || { printf 'FAIL  could not read the Multisig account — this verification is VOID\n' >&2; return 1; }
  threshold=$(printf '%s\n' "$ms" | awk '$1=="threshold" {print $2}')
  count=$(printf '%s\n' "$ms" | awk '$1!="threshold"' | wc -l | tr -d ' ')
  new_mask=$(printf '%s\n' "$ms" | awk -v k="$NEW_MEMBER" '$1==k {print $2}')
  old_hit=$(printf '%s\n' "$ms" | awk -v k="$OLD_MEMBER" '$1==k {print $1}')
  [ "$count" = "$WANT_COUNT" ] || { printf 'FAIL  %s members, expected %s\n' "$count" "$WANT_COUNT"; bad=1; }
  [ "$threshold" = "$WANT_THRESHOLD" ] || { printf 'FAIL  threshold %s, expected %s\n' "$threshold" "$WANT_THRESHOLD"; bad=1; }
  [ -z "$old_hit" ] || { printf 'FAIL  the rotated-out key is STILL a member\n'; bad=1; }
  [ -n "$new_mask" ] || { printf 'FAIL  the new key is NOT a member\n'; bad=1; }
  [ "$new_mask" = "$WANT_MASK" ] || { printf 'FAIL  new member mask is %s, expected %s\n' "${new_mask:-none}" "$WANT_MASK"; bad=1; }
  [ "$bad" = 0 ] && printf 'PASS  %s members, threshold %s, new key present with mask %s, old key gone\n' "$count" "$threshold" "$WANT_MASK"
  return "$bad"
}
check_squads_rotation
```

A mask FAIL is fixed now, while the approvers are at their wallets, by another
remove-and-add; found at the next upgrade, it is a cold ceremony.

## Phase 4 — Execute

An empty `$NEW` does not fail: it succeeds and empties every store. Every write
below chains its guard with `&&`, because an interactive shell prints a bare
`${NEW:?}` refusal and runs the next line anyway.

### 4.1 Mint, and put the value in `$NEW`

Mint at the provider, then in the shell that runs Phases 4 and 5:

```bash
read -rs NEW                   # paste; -r keeps backslashes, -s keeps it off screen
printf '%s' "$NEW" | digest    # non-EMPTY, and matches the provider's copy
```

If Alex holds the value as `$T` (`credential-filing` §5), either he runs Phases 4
and 5 in his terminal, or he enters it here with `read -rs NEW`. Say which.

### 4.2 File it in 1Password FIRST

An edit on the writing lane (field history makes it reversible). Update
`authorization-id`, `used-by` and the scope notes in the same edit if they changed.

```bash
: "${NEW:?refusing to file an empty value}" && op item edit "<item>" --vault <vault> "<field>[concealed]=$NEW"
```

```bash
op item get "<item>" --vault <vault> --fields label="<field>" --reveal | digest
printf '%s' "$NEW" | digest      # the two match, and NEITHER prints EMPTY
```

### 4.3 Update every registration, and prove each is accepted

Once per registration row from Phase 1: update it, then make the far side accept
the new identity (read the account back on-chain, one signed request, one test
webhook). A dashboard that "looks updated" is not a proof.

### 4.4 Write the runtime stores

**Heroku**, every app from Phase 1 (never for `MANAGED_WALLET_ENCRYPTION_KEY`; that is §2.1 step 5):

```bash
: "${NEW:?refusing to write — NEW is empty and this would blank <VAR> on every app}" &&
APPS="${APPS:?set APPS to the apps from your Phase 1 list, space separated}" &&
for app in $APPS; do
  heroku config:set "<VAR>=$NEW" --app "$app"
done
```

Read the output. Only once every app reported success, stamp the moment the
snapshot sweep below splits on (an early stamp keeps a stale snapshot):

```bash
ROTATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

**GitHub:** Actions by the stdin recipe in Phase 1; Dependabot is Alex's, at
`Settings → Secrets and variables → Dependabot`, given the repo list and secret
names, the value handed over per `credential-filing` §5. **Primaries:** run
`bin/ecosystem-build` once Heroku is right. **Desks:** reclaim finished ones
([`clean-infra`](clean-infra.md)); rewrite the line in live ones:

```bash
: "${NEW:?refusing to write — NEW is empty and this would strip <VAR> out of every desk .env}" &&
for f in /Users/alex/projects/*/.worktrees/*/.env; do
  [ -f "$f" ] || continue
  grep -q '^<VAR>=' "$f" || continue
  tmp=$(mktemp); grep -v '^<VAR>=' "$f" > "$tmp"; printf '<VAR>=%s\n' "$NEW" >> "$tmp"
  mv "$tmp" "$f"; chmod 600 "$f"
done
```

**Env snapshots**, after `bin/ecosystem-build`: delete those captured before
`ROTATED_AT`, keep the fresh one. This `rm` is irreversible; to keep stale
snapshots instead, skip it and record why in the receipt.

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

### 4.5 Migrate the data

Phase 2's answer, while the old value still works.

## Phase 5 — Verify liveness, store by store

Open with `printf '%s' "$NEW" | digest`; EMPTY means nothing below can be proved.

| Store | The proof |
|---|---|
| 1Password | field digest equals `$NEW`'s, neither EMPTY |
| Heroku, per app | config digest equals `$NEW`'s, AND `heroku run --exit-code --app <app> bin/rails runner '<a call only the new credential can make>'` succeeds |
| GitHub Actions | a re-run of the consuming workflow concludes green, with the consuming step run |
| Dependabot | the tab shows today's update; the next Dependabot `consumer-ci` run is green |
| `.env` and desks | per-file digest match, none EMPTY |
| Registration | the far side accepts a signed request, or the account reads back on-chain |
| Managed wallets | `solana:verify_managed_wallet_keys` prints `still-previous-key: 0` and `VERIFIED -- T of T`, and a runner check that `u.solana_keypair.to_base58 == u.web2_solana_address` prints `true` |

Not proofs: a green deploy (exit 0 only), `config:get` returning, a task that exits
0 (read its counters), and "the app is still up".

## Phase 6 — Retire the old value

The point of no return, only after Phase 5 passed for EVERY store on the list;
after a migration, after 24 to 48 hours of normal operation.

| Source | Revoke with |
|---|---|
| Heroku authorization | the admin lane (`HEROKU_STUDIO_ADMIN_API_KEY`), or Alex at https://dashboard.heroku.com/account/applications by description. Never the one this session uses |
| AWS access key | delete the old key on the IAM user |
| Provider API key | the provider's console: revoke, not hide |
| `VaultState` signer and Squads member | already evicted in 4.3; a Squads row still open means authority remains |
| 1Password field | overwritten in 4.2; history keeps it |
| Managed-wallet old key | `heroku config:unset MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS --app <app>`, then the verifier again; keep the `previous encryption key` field while a pre-rotation backup could be restored |

Then `unset NEW` (and `unset T`).

## Rollback

Before Phase 6: put the old value back in the runtime stores, revert every
registration, restore the 1Password field from history, re-run Phase 5 against
the old value, and find the cause. After Phase 6: forward only; mint again and
treat it as an incident.

| Symptom | Do this |
|---|---|
| One app 401s | re-run the fleet `has("<VAR>")` sweep from Phase 1; digest-compare each |
| Green until a Dependabot PR | Alex updates the Dependabot tab |
| The far side rejects the app | old value back on the app, finish 4.3, re-flip |
| The app cannot read credentials | restore the old `RAILS_MASTER_KEY`; redeploy key and `.enc` together |
| A desk fails, production fine | re-run the desk loop in 4.4, or reclaim the desk |
| Managed-wallet reads fail after the write | one `config:set` of `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD`, keeping the new key; rehearse again |
| Abandon a managed-wallet rotation | swap both values in ONE `config:set`, migrate, unset `…_PREVIOUS` only after `VERIFIED -- T of T` |
| Every store reads `<VAR>=` and Phase 5 said MATCH | Phase 4 ran with an empty `$NEW`: restore the old value everywhere, restart 4.1 |

## Phase 7 — The receipt

Append one row to the **Rotation log** in
[`secrets-rotation.md`](../../../system/secrets-rotation.md), committed through the
normal cycle:

`| <YYYY-MM-DD, UTC> | <1Password item name> | <why> | <stores updated> | <how verified> | <old value revoked: yes/no + when> | <task URL> |`

Update the item's row in
[`credential-inventory.md`](../../../modules/credential-inventory.md) only when a
recorded fact changed (authorization id, scope, consumer). No values, no digests.

## Background — not needed to execute

- `docs/agents/system/secrets-rotation.md`: per-credential recipes; where they
  disagree with this SOP, this SOP wins and the recipe is fixed in the same pass.
- `docs/agents/modules/credentials.md`: the access contract and the lanes.
- `turf-monster/docs/SOLANA.md` and `turf-vault/docs/KEY_ROTATION.md`: signer
  and Squads mechanics (take mechanism, not addresses, from the latter).

History: the long form, with its rationale and measurements, is
[`credential-rotation-2026-10-05.md`](../../../archive/credential-rotation-2026-10-05.md).
