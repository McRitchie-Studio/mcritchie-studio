# Credential Rotation SOP (Steffon)

## Status: Active

**When:** one filed credential is compromised, stale or due. Run top to bottom, once per
credential; never merge two credentials' Phase 4. Filing a NEW credential is
[`credential-filing`](credential-filing.md). A real exposure (money, customer data, production, a
public leak) rotates here first; lesser issues are triaged in
[`credential-issues`](../../../modules/credential-issues.md). **Precondition:** the admin lane,
`OP_ADMIN_SERVICE_ACCOUNT_TOKEN`: `source ~/.zprofile.admin`, never through a pipe (the token lands
in a subshell), then run each `op` call with `OP_SERVICE_ACCOUNT_TOKEN` set to the admin token's
value (sourcing alone leaves `op` on the agents token, and `studio-agents-admin` "isn't a vault"); with no such file, Alex runs `bin/setup-1pass-token --admin` once.
**Placeholders:** `<VAR>` is the env-var name; `<item>` `<field>` `<vault>` the 1Password home;
`<app>` `<file>` `<repo>` `<env>` one target; substitute each. This SOP assigns `$NEW`, `$OLD`,
`$APPS`, `$ROTATED_AT`.

**Never print the value** anywhere durable. List key names (`jq -r 'keys[]'`) and file names
(`grep -rl`); hold the value in one shell variable; keep digests in the shell (the repo is
public). A pushed value survives a force-push; a GitHub Support purge is Alex's call.

### Compare by digest — and a digest of nothing is not a comparison
Two EMPTY values match: `sha256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`,
which an unset var, a stripped `.env` line and a failed read all produce. Every comparison goes
through this helper, pasted into the shell that runs Phases 4 and 5:
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
Reads: the vault (4.2), an app (§2.1), and a `.env`, stripping one quote pair:
```bash
grep -m1 '^<VAR>=' <file> | sed -E 's/^[^=]+=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' | digest
```
EMPTY is the answer: stop; never retry with a bare `shasum`. `heroku config:get` is banned (absent
and empty print the same newline): ask `jq 'has("<VAR>")'` of `heroku config --json`. A failed
read is empty on stdout: first `heroku auth:whoami`, then `jq 'length'` (0 is a failed read).

## Phase 1 — Enumerate every store

Before minting, list every store (where, writer, value or public half): the list is the rotation.

| Store | How to ask | Writer |
|---|---|---|
| 1Password | `op item list --vault <vault> --format json \| jq -r '.[].title'` | the vault's lane (`credential-filing` §4) |
| Heroku, every app | the fleet sweep below | any Heroku lane |
| GitHub Actions, repo and environment | `gh secret list -R McRitchie-Studio/<repo>` (`--env <env>`) | admin lane, `github.mcritchie-admin` |
| GitHub Dependabot | `gh secret list --app dependabot -R McRitchie-Studio/<repo>` | Alex |
| `.env`, primaries and desks | `grep -rl '^<VAR>=' /Users/alex/projects/*/.env /Users/alex/projects/*/.worktrees/*/.env` | you |
| Env snapshots | `ls /Users/alex/projects/mcritchie-studio/tmp/env-snapshot-*.json` | you |
| Public half | on-chain account, provider dashboard, webhook | often a third party |

```bash
for app in $(heroku apps --all --json | jq -r '.[].name'); do
  printf '%-26s keys=%-4s has=%s\n' "$app" "$(heroku config --json --app "$app" | jq 'length')" \
    "$(heroku config --json --app "$app" | jq 'has("<VAR>")')"
done
```
`keys=0` is a failed read. A lane sees only its own vaults (on `(101)`, check
`op service-account ratelimit`). Dependabot is its own store; `studio-engine`'s `consumer-ci.yml` reads
`MCRITCHIE_AGENT_APP_ID` and `MCRITCHIE_AGENT_PRIVATE_KEY` there. Desks hold birth-day `.env`
copies. The hub's CI `HEROKU_API_KEY` (`heroku.studio.applications`) is scripted:
`bin/rotate-heroku-ci-key --dry-run`, then without the flag, then refresh
`HEROKU_STUDIO_APPLICATIONS_API_KEY` in `~/.zprofile.admin`. Actions secrets (4.4), admin lane:
```bash
export GH_TOKEN="$(GH_APP_ITEM=github.mcritchie-admin /Users/alex/projects/mcritchie-studio/bin/gh-token)"
: "${NEW:?refusing to set an empty value}" && printf '%s' "$NEW" | gh secret set <VAR> --env <env> -R McRitchie-Studio/<repo>
```

## Phase 2 — The data question

What did the old value authenticate or ENCRYPT, and does it survive? A key that only authenticates
costs nothing extra. `SECRET_KEY_BASE` logs everyone out and kills magic links: announce it. A
registered public half (a Solana key, a webhook secret) moves first (Phase 3).
`MANAGED_WALLET_ENCRYPTION_KEY` is §2.1 (it replaces 4.1 to 4.5). `RAILS_MASTER_KEY` re-encrypts:
`EDITOR='code --wait' bin/rails credentials:edit`, copy the plaintext to
`(umask 077; : > "$TMPDIR/creds.$$")`, delete the `.enc` and `config/master.key`, re-run
`credentials:edit`, paste, commit the new `.enc`, `rm -f` the scratch file; key and ciphertext go
live in one deploy, per app. Keep the old value until a migration verifies; no migration in the
running release, no rotation.

### 2.1 `MANAGED_WALLET_ENCRYPTION_KEY` — deploy first, then migrate
`MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS` opens old rows, never seals. Per app: **Gate 0**, the
code RUNS (only `VERIFIED -- N of N row(s) open under the current key alone.`, N equal to the
runner's count; record N); mint; hold the live old key (vault and app digests match, none EMPTY,
`$OLD` is 64 hex; otherwise stop and route to Jasper):
```bash
heroku run --exit-code --app turf-monster-mainnet bin/rails solana:verify_managed_wallet_keys
heroku run --exit-code --app turf-monster-mainnet bin/rails runner \
  'puts User.where.not(encrypted_web2_solana_private_key: [nil, ""]).count'
NEW=$(ruby -e 'require "securerandom"; print SecureRandom.hex(32)')
OLD=$(op item get agent.managed_wallet --vault studio-agents --fields label="encryption key" --reveal)
printf '%s' "$NEW" | digest; printf '%s' "$OLD" | digest
heroku config --json --app turf-monster-mainnet | jq -r '.["MANAGED_WALLET_ENCRYPTION_KEY"] // empty' | digest
[[ "$OLD" =~ ^[0-9a-fA-F]{64}$ ]] && echo "OLD: 64 hex" || echo "OLD: NOT 64 hex"
```
Rehearse on a one-off dyno, app untouched. Pass only on header `ROTATION`, the counts
`total: N  would-migrate: N  already-new: 0  failed: 0`, and a last line `DRY RUN CLEAN`:
```bash
: "${NEW:?NEW is not set}" && : "${OLD:?OLD is not set}" && [ "$NEW" != "$OLD" ] &&
heroku run --exit-code --app turf-monster-mainnet \
  --env "DRY_RUN=1;MANAGED_WALLET_ENCRYPTION_KEY=$NEW;MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD" \
  bin/rails solana:reencrypt_managed_wallets
```
File both (replaces 4.2): add field `previous encryption key` = `$OLD` to `agent.managed_wallet`
first, then replace `encryption key`; read both back. Write the app in ONE command (replaces
4.4); from here `$NEW` never leaves the app:
```bash
: "${NEW:?refusing -- NEW is empty}" && : "${OLD:?refusing -- OLD is empty}" &&
[ "$NEW" != "$OLD" ] &&
heroku config:set "MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD" \
  "MANAGED_WALLET_ENCRYPTION_KEY=$NEW" --app turf-monster-mainnet
```
Migrate (replaces 4.5): the same task with `--env "DRY_RUN=1"`, then without it. Complete only on
`failed: 0`, `Read-back: T of T` and a last line `COMPLETE`; `NOT COMPLETE` is safe to re-run.
A COMPROMISED key is an incident (old backups still open with it): rotate, move funds, tell Alex.

## Phase 3 — Order the moves

Registration before config: mint, file in 1Password, update and prove every registration, write
the runtime stores, migrate, verify every store, then revoke (the point of no return). Where a
provider allows two live keys (`agent.aws`, IAM user `mcritchie-s3`), add the second, deploy and
verify everywhere, then delete the first. The signing-key case: `agent.xan.solana`
(`studio-agents-admin`, field `private key`, `8K81…`), `SOLANA_ADMIN_KEY` on `turf-monster-qa`
and `turf-monster-mainnet`:

| Registration | Updated by | Proof |
|---|---|---|
| turf-vault `VaultState.signers` | `update_signers`, cosigned by signers who stay | read `VaultState` back |
| Squads V4 upgrade multisig, per cluster | one config transaction, `app.squads.so` | `check_squads_rotation` below |
| `scripts/squad-upgrade.js` devnet seat `xan` (`scripts/lib/squad-clusters.js`) | a turf-vault PR to the seat's `pubkey` | the bot key comes per run from `SQUAD_KEY_XAN`, filled by an admin-lane 1Password read; Alex's key (`7ZDJ…`) is a Phantom export with no filed item |

`update_signers` replaces the whole set (deployed: three slots, 2-of-3) and its cosigners must
survive it (`SignerContinuityRequired`, 6017), so **the outgoing key never signs**. Fund the new
key first; it pays fees for `create_contest`, `mint_entry_token` and `enter_contest`. Verify: new
in, old out, cosigners kept. Squads is a separate authority: land or cancel approved upgrade
proposals, read the mask below, then propose ONE transaction, `removeMember(<old pubkey>)` +
`addMember(<new pubkey>, { mask: $WANT_MASK })`, threshold unchanged, clean approvers only (two
transactions stale the second, 6007). Then the devnet seat PR, then Phase 4.
```bash
OLD_MEMBER=<old pubkey>   # squads_members() is defined in the next section
BEFORE=$(squads_members) || BEFORE=
WANT_MASK=$(printf '%s\n' "$BEFORE" | awk -v k="$OLD_MEMBER" '$1==k { print $2 }')
WANT_THRESHOLD=$(printf '%s\n' "$BEFORE" | awk '$1=="threshold" { print $2 }')
WANT_COUNT=$(printf '%s\n' "$BEFORE" | awk '$1!="threshold"' | wc -l | tr -d ' ')
: "${WANT_MASK:?the outgoing key is not a member; read again}" "${WANT_THRESHOLD:?no threshold in the read}"
printf 'grant the new key mask %s (what %s holds now)\n' "$WANT_MASK" "$OLD_MEMBER"
printf 'expect %s members at threshold %s after the rotation\n' "$WANT_COUNT" "$WANT_THRESHOLD"
```

#### Verifying the Squads rotation
```bash
SQUADS_CLUSTER=<cluster>   # devnet or mainnet; no default. Live chain, not squad.json.
squads_members() {
  ( cd /Users/alex/projects/turf-vault && SQUADS_CLUSTER="$SQUADS_CLUSTER" node -e "
      const multisig = require(\"@sqds/multisig\"); const { Connection, PublicKey } = require(\"@solana/web3.js\");
      const c = require(\"./scripts/lib/squad-clusters\").resolveCluster(process.env.SQUADS_CLUSTER);
      (async () => { const conn = new Connection(c.rpcUrl);
        if ((await conn.getGenesisHash()) !== c.genesisHash) throw new Error(\"wrong cluster RPC\");
        const ms = await multisig.accounts.Multisig.fromAccountAddress(conn, new PublicKey(c.multisigPda));
        console.log(\"threshold \" + ms.threshold);
        for (const m of ms.members) console.log(m.key.toBase58() + \" \" + m.permissions.mask);
      })().catch((e) => { console.error(e.message); process.exit(1); });" )
}
```
```bash
NEW_MEMBER=<new pubkey>
: "${OLD_MEMBER:?}" "${WANT_MASK:?}" "${WANT_COUNT:?}" "${WANT_THRESHOLD:?run the mask step first}"
check_squads_rotation() {
  local ms; local bad=0; local threshold count new_mask old_hit
  ms=$(squads_members) || { printf 'FAIL  could not read the Multisig account; VOID\n' >&2; return 1; }
  threshold=$(printf '%s\n' "$ms" | awk '$1=="threshold" {print $2}')
  count=$(printf '%s\n' "$ms" | awk '$1!="threshold"' | wc -l | tr -d ' ')
  new_mask=$(printf '%s\n' "$ms" | awk -v k="$NEW_MEMBER" '$1==k {print $2}')
  old_hit=$(printf '%s\n' "$ms" | awk -v k="$OLD_MEMBER" '$1==k {print $1}')
  [ "$count" = "$WANT_COUNT" ] || { printf 'FAIL  %s members, expected %s\n' "$count" "$WANT_COUNT"; bad=1; }
  [ "$threshold" = "$WANT_THRESHOLD" ] || { printf 'FAIL  threshold %s, expected %s\n' "$threshold" "$WANT_THRESHOLD"; bad=1; }
  [ -z "$old_hit" ] || { printf 'FAIL  the rotated-out key is STILL a member\n'; bad=1; }
  [ "$new_mask" = "$WANT_MASK" ] || { printf 'FAIL  new member mask is %s, expected %s\n' "${new_mask:-none}" "$WANT_MASK"; bad=1; }
  [ "$bad" = 0 ] && printf 'PASS  %s members, threshold %s, new key at mask %s, old key gone\n' "$count" "$threshold" "$WANT_MASK"
  return "$bad"
}
check_squads_rotation
```
Fix a mask FAIL now with one more transaction: `removeMember(<new pubkey>)` + `addMember(<new pubkey>, { mask: $WANT_MASK })`.

## Phase 4 — Execute

### 4.1 Mint, and put the value in `$NEW`
Mint at the provider. An empty `$NEW` empties every store, so each write chains its guard with `&&`
(an interactive shell prints a bare refusal and runs on). If Alex holds the value as `$T`
(`credential-filing` §5), he runs Phases 4 and 5 or enters it here; say which.
```bash
read -rs NEW                   # in the shell that runs Phases 4 and 5
printf '%s' "$NEW" | digest    # non-EMPTY, matches the provider's copy
```

### 4.2 File it in 1Password FIRST
On the writing lane, which field history makes reversible. Update `authorization-id`, `used-by`
and the scope notes in the same edit when they changed:
```bash
: "${NEW:?refusing to file an empty value}" && op item edit "<item>" --vault <vault> "<field>[concealed]=$NEW"
op item get "<item>" --vault <vault> --fields label="<field>" --reveal | digest   # equals $NEW's digest
```

### 4.3 Update every registration, and prove each is accepted
Per registration row: update it, then make the far side accept the new identity (an on-chain
read, a signed request, a test webhook). A dashboard that looks updated is not a proof.

### 4.4 Write the runtime stores
Heroku, never for `MANAGED_WALLET_ENCRYPTION_KEY` (§2.1):
```bash
: "${NEW:?refusing to write — NEW is empty and this would blank <VAR> on every app}" &&
APPS="${APPS:?set APPS to the apps from your Phase 1 list, space separated}" &&
for app in $APPS; do
  heroku config:set "<VAR>=$NEW" --app "$app"
done
ROTATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)   # keep only if EVERY app reported success
```
GitHub: Actions by the Phase 1 recipe; Dependabot is Alex's tab, given the repos and secret
names, the value handed over per `credential-filing` §5. Primaries: `bin/ecosystem-build`.
Desks: reclaim finished ones ([`clean-infra`](clean-infra.md)) and rewrite live ones:
```bash
: "${NEW:?refusing to write — NEW is empty and this would strip <VAR> out of every desk .env}" &&
for f in /Users/alex/projects/*/.worktrees/*/.env; do
  [ -f "$f" ] || continue
  grep -q '^<VAR>=' "$f" || continue
  tmp=$(mktemp); grep -v '^<VAR>=' "$f" > "$tmp"; printf '<VAR>=%s\n' "$NEW" >> "$tmp"
  mv "$tmp" "$f"; chmod 600 "$f"
done
```
Env snapshots, after `bin/ecosystem-build`; this irreversible sweep keeps only the fresh one:
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

| Store | Proof |
|---|---|
| 1Password, Heroku config, `.env` | the digest equals `$NEW`'s, and neither side is EMPTY |
| Heroku runtime | `heroku run --exit-code --app <app> bin/rails runner '<a call only the new value can make>'` |
| Actions · Dependabot | the consuming workflow re-runs green · the next Dependabot `consumer-ci` run is green |
| Managed wallets | `solana:verify_managed_wallet_keys` prints `still-previous-key: 0` and `VERIFIED -- T of T` |

Not proofs: a green deploy, `config:get` returning, a task exiting 0 (read its counters), "the
app is still up".

## Phase 6 — Retire the old value

Only after Phase 5 passed everywhere (after a migration, 24 to 48 hours later); then `unset NEW T`.

| Source | Revoke with |
|---|---|
| Heroku authorization | the admin lane (`HEROKU_STUDIO_ADMIN_API_KEY`), or Alex at https://dashboard.heroku.com/account/applications; never this session's own |
| AWS key · provider key | delete it on the IAM user · revoke it in the provider console |
| Signer, Squads member | already evicted in 4.3 |
| Managed-wallet old key | `heroku config:unset MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS --app <app>`, then the verifier; keep the 1Password field while an old backup could return |

## Rollback

Before Phase 6: put the old value back in the runtime stores, revert every registration, restore
the 1Password field from history, and re-run Phase 5. After Phase 6: forward only, an incident.

| Symptom | Do this |
|---|---|
| The far side rejects the app | old value back on the app, finish 4.3, re-flip |
| The app cannot read credentials | restore the old `RAILS_MASTER_KEY`; deploy key and `.enc` together |
| Managed-wallet reads fail | one `config:set` of `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS=$OLD`, keeping the new key |
| Stores read `<VAR>=` and Phase 5 said MATCH | restore the old value everywhere; restart at 4.1 |

## Phase 7 — The receipt

Append, with no values or digests, to the **Rotation log** in [`secrets-rotation.md`](../../../system/secrets-rotation.md):
`| <YYYY-MM-DD, UTC> | <1Password item name> | <why> | <stores updated> | <how verified> | <old value revoked: yes/no + when> | <task URL> |`.
Update [`credential-inventory.md`](../../../modules/credential-inventory.md) only when a recorded fact changed.

## Background — not needed to execute

`system/secrets-rotation.md` (recipes; this SOP wins), `modules/credentials.md`, `turf-monster/docs/SOLANA.md`.

History: the long form, with rationale and measurements, is [`credential-rotation-2026-10-05.md`](../../../archive/credential-rotation-2026-10-05.md).
