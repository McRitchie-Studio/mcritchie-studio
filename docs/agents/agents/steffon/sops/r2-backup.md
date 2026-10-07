# R2 Backup
<!-- registry: backup bucket, nightly run, garbage collection, restore -->

## Status: Active

This is Steffon's `r2-backup` SOP. Cloudflare R2 has **no object versioning**,
so an overwrite or delete on a production bucket is gone from that bucket the
moment it happens. This act is the undo: a per-app backup bucket, a mirror of
production refreshed on every run, a dated archive of everything a run saw
overwritten or deleted, garbage collection that expires the archive, and a
restore drill that proves the whole thing brings an object back. Alex approved
it on 2026-09-26 and asked for it to be a repeatable part of the system.

It has four acts, each runnable on its own:

| Act | When | Section |
|---|---|---|
| **Enable** | once per app, when its R2 pair starts holding real objects | §2 |
| **Run** | every night (and before any bulk operation on production) | §3 |
| **Collect** | automatic (R2 lifecycle); the manual fallback on demand | §4 |
| **Restore** | when an object must come back, and as a drill after Enable | §5 |

**Recovery window.** A run every night gives a recovery point of at most one
day. The archive keeps each overwritten or deleted object for **30 days**; the
current mirror keeps the latest copy of every live object indefinitely.

**Run is automated nightly.** The workflow `.github/workflows/r2-backup.yml`
runs `bin/r2-backup run <app>` for every app in its matrix at 09:37 UTC (03:37
Denver in summer; off the hour, because GitHub runs top-of-hour schedules hours
late). A failed night opens an issue titled `R2 backup failing:
<app>` on the hub repo, and the next good night closes it; no open issue and a
fresh receipt means the undo is current. Run by hand (§3) only before a bulk
operation or to recover from a failure. The automation landed in task
`automate-nightly-r2-backup`.

## What this act is NOT

- **It never writes production except in Restore**, and Restore uses the admin
  lane deliberately: no routine key can write production and read backup both.
- **It never deletes `current/`.** Collection touches only `archive/` and
  `_receipts/`. The manual collector (§4) also refuses unless a good run landed
  in the last 48 hours; the lifecycle rules do not check, and expire the archive
  on age alone, which is why a failed night must be noticed within 30 days.
- **It never merges, deploys, or moves board tasks.**

## 1. Open the lane

The same admin lane as `bucket-provision`
([`bucket-provision.md`](bucket-provision.md) §1). Prerequisites on the
machine: `op`, the `aws` CLI v2 and `rclone` (`brew install rclone`; measured
with v1.75.1).

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
export CF_TOKEN=$(op read "op://studio-agents-admin/cloudflare.studio.provision/api-token")
export CF_ACCOUNT=$(op read "op://studio-agents-admin/cloudflare.studio.provision/account-id")
APP=<app-slug>
mkdir -p "$HOME/.mcr-r2"
```

**The admin token's own S3 keys.** Setting lifecycle rules (§2) and Restore
(§5) use the provisioning token through the S3 API. Its access key id is the
token's id (from `tokens/verify`); its secret is the SHA-256 of the token.

```bash
export ADMIN_ID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/tokens/verify" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')
export ADMIN_SECRET=$(printf %s "$CF_TOKEN" | shasum -a 256 | cut -d' ' -f1)
export R2_ENDPOINT="https://$CF_ACCOUNT.r2.cloudflarestorage.com"
```

## 2. Enable — backup bucket, backup token, lifecycle

- **Bucket** `<app>-backup`, location hint `enam`, private.
- **Token** `r2-<app>-backup`: *Bucket Item Read* on `<app>-production` plus
  *Bucket Item Write* on `<app>-backup`. It can read production and nothing
  else there; the app's own prod and dev tokens cannot see the backup bucket at
  all, so a compromised app key cannot delete its own history.
- **Record** two fields added to the existing `r2.<app>` item:
  `access-key-id-backup`, `secret-access-key-backup`.

```bash
cat > "$HOME/.mcr-r2/enable.py" <<'PY'
import hashlib, json, os, subprocess, sys, urllib.request, urllib.error
APP = sys.argv[1]
TOK, ACCT = os.environ["CF_TOKEN"], os.environ["CF_ACCOUNT"]
API = f"https://api.cloudflare.com/client/v4/accounts/{ACCT}"
ITEM_WRITE = "2efd5506f9c8494dacb1fa10a3e7d5b6"  # Workers R2 Storage Bucket Item Write
ITEM_READ = "6a018a9f2fc74eb6b293b0c548f38b39"   # Workers R2 Storage Bucket Item Read

def cf(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {TOK}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r: return json.load(r)
    except urllib.error.HTTPError as e: return json.load(e)

def res(bucket): return {f"com.cloudflare.edge.r2.bucket.{ACCT}_default_{bucket}": "*"}

got = subprocess.run(["op", "item", "get", f"r2.{APP}", "--vault", "studio-agents", "--format", "json"],
                     capture_output=True, text=True)
if got.returncode != 0: sys.exit(f"cannot read r2.{APP}: {got.stderr.strip()[:200]} (run bucket-provision first)")
if any(f.get("label") == "access-key-id-backup" for f in json.loads(got.stdout)["fields"]):
    sys.exit(f"r2.{APP} already holds a backup token; refusing to mint a second")
d = cf("POST", "/r2/buckets", {"name": f"{APP}-backup", "locationHint": "enam"})
if not d.get("success"): sys.exit(f"bucket {APP}-backup: FAILED {d.get('errors')}")
print(f"bucket {APP}-backup: created")
d = cf("POST", "/tokens", {"name": f"r2-{APP}-backup", "policies": [
    {"effect": "allow", "permission_groups": [{"id": ITEM_READ}], "resources": res(f"{APP}-production")},
    {"effect": "allow", "permission_groups": [{"id": ITEM_WRITE}], "resources": res(f"{APP}-backup")}]})
if not d.get("success"): sys.exit(f"token r2-{APP}-backup: FAILED {d.get('errors')}")
t = d["result"]
p = subprocess.run(["op", "item", "edit", f"r2.{APP}", "--vault", "studio-agents",
    f"access-key-id-backup[concealed]={t['id']}",
    f"secret-access-key-backup[concealed]={hashlib.sha256(t['value'].encode()).hexdigest()}"],
    capture_output=True, text=True)
if p.returncode != 0: sys.exit(f"1Password write FAILED: {p.stderr.strip()[:200]} — revoke token r2-{APP}-backup; bucket {APP}-backup was created and is empty")
print(f"token r2-{APP}-backup: minted and filed in r2.{APP}")
PY
python3 "$HOME/.mcr-r2/enable.py" "$APP"
```

**Recovering a partial Enable.** The script creates the bucket before it mints
the token, so a failure after that leaves `<app>-backup` behind and a re-run
stops at bucket creation. Revoke any `r2-<app>-backup` token the run minted
(**Manage Account → Account API Tokens**), confirm the bucket is empty, delete
it (`DELETE /accounts/<id>/r2/buckets/<app>-backup`), and re-run. Like
`bucket-provision`, the script hands the derived keys to `op item edit` as
command-line arguments, visible to the same macOS user's `ps` for a second; run
it on Alex's machine only.

**Why the backup key lives in `r2.<app>`.** One item per app keeps every key
for that app's storage in one record, and the backup key cannot write
production, so filing it beside the app keys widens nothing.

**Lifecycle rules are the garbage collector.** R2 deletes an object under a
prefix once it is N days old, measured from when it was written into the
backup bucket (an archived object is written on the night it was archived),
typically within 24 hours of expiry.

```bash
cat > "$HOME/.mcr-r2/lifecycle.json" <<'J'
{"Rules":[
 {"ID":"expire-archive-30d","Status":"Enabled","Filter":{"Prefix":"archive/"},"Expiration":{"Days":30}},
 {"ID":"expire-receipts-180d","Status":"Enabled","Filter":{"Prefix":"_receipts/"},"Expiration":{"Days":180}}]}
J
AWS_ACCESS_KEY_ID=$ADMIN_ID AWS_SECRET_ACCESS_KEY=$ADMIN_SECRET AWS_DEFAULT_REGION=auto \
  aws s3api put-bucket-lifecycle-configuration --endpoint-url "$R2_ENDPOINT" \
  --bucket "$APP-backup" --lifecycle-configuration "file://$HOME/.mcr-r2/lifecycle.json"
AWS_ACCESS_KEY_ID=$ADMIN_ID AWS_SECRET_ACCESS_KEY=$ADMIN_SECRET AWS_DEFAULT_REGION=auto \
  aws s3api get-bucket-lifecycle-configuration --endpoint-url "$R2_ENDPOINT" --bucket "$APP-backup" \
  --query 'Rules[].[ID,Status,Filter.Prefix,Expiration.Days]' --output text
# must print both rules, Enabled, archive/ 30 and _receipts/ 180
```

`current/` has no rule on purpose: it is the mirror, and expiring it would
delete the backup of every object that has not changed in 30 days.

**Isolation probes.** Every probe must be refused with `AccessDenied`; any
other error is inconclusive, not a pass.

```bash
cat > "$HOME/.mcr-r2/isolation.sh" <<'SH'
#!/bin/zsh
APP=$1; I="op://studio-agents/r2.$APP"; EP=$(op read "$I/endpoint")
BID=$(op read "$I/access-key-id-backup"); BSEC=$(op read "$I/secret-access-key-backup")
PID=$(op read "$I/access-key-id-prod");   PSEC=$(op read "$I/secret-access-key-prod")
DID=$(op read "$I/access-key-id-dev");    DSEC=$(op read "$I/secret-access-key-dev")
BODY=$(mktemp); ERR=$(mktemp); echo probe > "$BODY"; FAILS=0
s3()  { local id=$1 sec=$2; shift 2; AWS_ACCESS_KEY_ID=$id AWS_SECRET_ACCESS_KEY=$sec AWS_DEFAULT_REGION=auto \
        aws s3api --endpoint-url "$EP" "$@" >/dev/null 2>"$ERR"; }
bad() { if "$@"; then echo "  VIOLATION"; FAILS=$((FAILS+1))
        elif grep -q AccessDenied "$ERR"; then echo "  PASS (AccessDenied)"
        else echo "  INCONCLUSIVE: $(head -c 160 "$ERR")"; FAILS=$((FAILS+1)); fi; }
echo "backup key cannot write production";  bad s3 $BID $BSEC put-object --bucket $APP-production --key _probe/x --body "$BODY"
echo "backup key cannot delete production"; bad s3 $BID $BSEC delete-object --bucket $APP-production --key _probe/x
echo "prod key cannot read backup";         bad s3 $PID $PSEC list-objects-v2 --bucket $APP-backup
echo "prod key cannot delete backup";       bad s3 $PID $PSEC delete-object --bucket $APP-backup --key current/_probe/x
echo "dev key cannot read backup";          bad s3 $DID $DSEC list-objects-v2 --bucket $APP-backup
rm -f "$BODY" "$ERR"; echo "$APP: $FAILS failure(s)"; exit $FAILS
SH
zsh "$HOME/.mcr-r2/isolation.sh" "$APP"   # must end "<app>: 0 failure(s)"
```

Then run §3 once and the §5 drill. Enable is not done until a restore has
brought an object back.

## 3. Run — mirror plus archive, with a receipt

`bin/r2-backup run <app>` makes `<app>-backup/current/` equal production.
Every object the sync would overwrite or delete is first moved into
`archive/<stamp>/` by rclone's `--backup-dir`, so the archive holds exactly what
changed, keyed by run. Each run writes `_receipts/<stamp>.json`. Logic and
guards: `bin/lib/r2_backup.rb`, unit-tested in `test/lib/r2_backup_test.rb`.

```bash
cd /Users/alex/projects/mcritchie-studio
bin/r2-backup run "$APP" --op   # --op reads the backup keys from r2.<app>
```

A run is **ok** only when rclone exits 0 **and** `current/` holds as many
objects as production; the receipt records `ok`, and a not-ok run exits 1 with
the reason. Two guards stop a wipe in production from being copied into the
mirror:

- **The drop guard.** If production holds at least 20% fewer objects (and at
  least 10 fewer, or none at all) than at the last ok run, the run refuses,
  writes a not-ok receipt and exits 1. Nothing is synced.
- **The delete cap.** Every sync carries `--max-delete`, set to twice a fifth of
  `current/` (floor 20). Twice, because rclone counts more than one delete per
  object when `--backup-dir` is set: measured on R2 2026-09-26, deleting 12
  objects tripped a cap of 13 with only 3 gone. A tripped cap stops the sync
  partway (rclone exit 7). That is safe: every object it touched is already in
  the archive, and the next run finishes.

**A deliberate large delete** in production refuses the next run by design.
Once someone has confirmed the delete was intended, mirror it once:

```bash
bin/r2-backup run "$APP" --accept-drop --op
```

That lifts both guards for that run only and records `accepted_drop` in the
receipt. The deleted objects still land in the archive for 30 days.

**Before any bulk delete or rewrite on a production bucket, run a backup first
and read its output.** That is the one moment the undo matters most.

## 4. Collect — garbage collection

**Automatic.** The lifecycle rules from §2 expire `archive/` at 30 days and
`_receipts/` at 180. Re-read them with the `get-bucket-lifecycle-configuration`
command in §2 whenever this act runs; a missing rule is a leak, not an
emergency.

**Manual fallback** (a rule was removed, or the archive must shrink now):

```bash
bin/r2-backup gc "$APP" --op                    # dry run, 30 days
bin/r2-backup gc "$APP" --days 30 --apply --op  # only after reading the dry run
```

It deletes only stamp-named `archive/<stamp>/` folders older than `--days`,
never `current/`, and **refuses** (exit 2) unless the newest receipt is under 48
hours old and ok, counts included. A broken backup must never let collection eat
the only history.

## 5. Restore — and the drill

Restore reads the backup and writes production, which no routine key may do,
so it runs as the admin lane from §1. Find the object first: the latest copy of
a live object is under `current/`; an overwritten or deleted one is under the
newest `archive/<stamp>/` that holds it.

```bash
export RCLONE_CONFIG_ADMIN_TYPE=s3 RCLONE_CONFIG_ADMIN_PROVIDER=Cloudflare RCLONE_CONFIG_ADMIN_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_ADMIN_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_ADMIN_ACCESS_KEY_ID="$ADMIN_ID" RCLONE_CONFIG_ADMIN_SECRET_ACCESS_KEY="$ADMIN_SECRET"
KEY=<object-key-as-the-app-stores-it>
rclone lsf -R "admin:$APP-backup/archive/" | grep -F "$KEY"      # which runs archived it
STAMP=<the archive stamp to restore from>
rclone copyto "admin:$APP-backup/archive/$STAMP/$KEY" "admin:$APP-production/$KEY"
rclone cat "admin:$APP-production/$KEY" | head -c 200           # read it back
```

Restoring a whole prefix is the same with `rclone copy` on a folder. Restore
never deletes from production; a restore that must also remove objects is a
bulk operation and needs Alex's yes.

**The drill** (after Enable, and whenever the scripts change): put two objects
under `_backup-drill/` in production with the prod key, Run, overwrite one and
delete the other, Run again, confirm `archive/<stamp>/_backup-drill/` holds the
old version of the first and the deleted second, restore the second, read it
back, then delete the drill objects from production and Run once more so the
mirror is clean. The drill's archive expires with the rest. Seeding with the
prod key, from the lane in §1:

```bash
export RCLONE_CONFIG_P_TYPE=s3 RCLONE_CONFIG_P_PROVIDER=Cloudflare RCLONE_CONFIG_P_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_P_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_P_ACCESS_KEY_ID=$(op read "op://studio-agents/r2.$APP/access-key-id-prod")
export RCLONE_CONFIG_P_SECRET_ACCESS_KEY=$(op read "op://studio-agents/r2.$APP/secret-access-key-prod")
echo "version-1" | rclone rcat "p:$APP-production/_backup-drill/a.txt"
echo "to be deleted" | rclone rcat "p:$APP-production/_backup-drill/b.txt"
```

Deleting the drill objects afterwards is a deliberate drop only if production
held few other objects; if the next run refuses, confirm and use
`--accept-drop` (§3).

## 6. Record

- **Automate it.** File the backup keys as the hub repo's Actions secrets
  `R2_BACKUP_<APP>_ACCESS_KEY_ID` and `R2_BACKUP_<APP>_SECRET_ACCESS_KEY`
  (upper-cased, dashes to underscores; the deployer identity can write them,
  the agent App cannot), and add the app to the matrix in
  `.github/workflows/r2-backup.yml`. Pipe each value through `printf %s
  "$(op read …)"`: `op read` ends in a newline, and a newline in a key breaks
  it. `R2_ENDPOINT` is one secret for the whole account.
- Mark the app's backup as enabled in the R2 census in
  [`../../../modules/object-storage.md`](../../../modules/object-storage.md),
  with the date of the drill.
- The `r2.<app>` row in
  [`../../../modules/credential-inventory.md`](../../../modules/credential-inventory.md)
  already names the backup fields; nothing to add per app.
- Remove the Enable helpers: `rm -rf "$HOME/.mcr-r2"`.
- Close the activity:
  `bin/agent-activity end --outcome "r2-backup <act> for <app>"`.

## Background — not needed to execute

R2's gaps against the S3 rules (no versioning, why this act exists), the tiers,
and the census: [`../../../modules/object-storage.md`](../../../modules/object-storage.md).
The first live run was on `moms-app` on 2026-09-26 with hand-written scripts:
three runs, archive held the
overwritten and deleted objects, restore brought the deleted one back, the
collection refusal fired on a simulated failed run, and all five isolation
probes were refused with `AccessDenied`. The same evening `bin/r2-backup`
replaced the scripts and was proven on the same bucket: an ok run, a wipe of 12
objects refused with `current/` intact, and an `--accept-drop` run that
mirrored the deliberate delete.
