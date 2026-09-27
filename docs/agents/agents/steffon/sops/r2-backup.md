# R2 Backup

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

**Scheduling is not automated yet.** Until the nightly-automation task ships,
Run is performed by hand. That gap is stated, not hidden: a production bucket
with Enable done and no recent run receipt has a stale undo.

## What this act is NOT

- **It never writes production except in Restore**, and Restore uses the admin
  lane deliberately: no routine key can write production and read backup both.
- **It never deletes `current/`.** Collection touches only `archive/<stamp>/`
  folders, and only after a successful run in the last 48 hours.
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
if p.returncode != 0: sys.exit(f"1Password write FAILED: {p.stderr.strip()[:200]} — revoke token r2-{APP}-backup")
print(f"token r2-{APP}-backup: minted and filed in r2.{APP}")
PY
python3 "$HOME/.mcr-r2/enable.py" "$APP"
```

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

`rclone sync` makes `<app>-backup/current/` equal production. Every object the
sync would overwrite or delete is first moved to `archive/<stamp>/` by
`--backup-dir`, so the archive holds exactly what changed, keyed by run. Each
run writes a receipt to `_receipts/<stamp>.json` with counts and the rclone
exit status; collection (§4) reads it.

```bash
cat > "$HOME/.mcr-r2/backup.sh" <<'SH'
#!/bin/zsh
set -u
APP=$1; I="op://studio-agents/r2.$APP"
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_R2_ENDPOINT=$(op read "$I/endpoint")
export RCLONE_CONFIG_R2_ACCESS_KEY_ID=$(op read "$I/access-key-id-backup")
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$(op read "$I/secret-access-key-backup")
STAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
rclone sync "r2:$APP-production" "r2:$APP-backup/current" --backup-dir "r2:$APP-backup/archive/$STAMP" -q
RC=$?
PROD=$(rclone size "r2:$APP-production" --json 2>/dev/null)
CUR=$(rclone size "r2:$APP-backup/current" --json 2>/dev/null)
ARC=$(rclone size "r2:$APP-backup/archive/$STAMP" --json 2>/dev/null || echo '{"count":0,"bytes":0}')
printf '{"app":"%s","stamp":"%s","rclone_exit":%d,"production":%s,"current":%s,"archived":%s}\n' \
  "$APP" "$STAMP" $RC "$PROD" "$CUR" "$ARC" | tee /dev/stderr | rclone rcat "r2:$APP-backup/_receipts/$STAMP.json"
exit $RC
SH
zsh "$HOME/.mcr-r2/backup.sh" "$APP"
```

Read the receipt it prints: `rclone_exit` must be `0` and `production.count`
must equal `current.count`. A mismatch is a failed run whatever the exit code
says. rclone's `Config file ... not found - using defaults` notice is expected:
the remote is configured entirely from `RCLONE_CONFIG_R2_*` variables.

**Before any bulk delete or rewrite on a production bucket, run a backup first
and read its receipt.** That is the one moment the undo matters most.

## 4. Collect — garbage collection

**Automatic.** The lifecycle rules from §2 expire `archive/` at 30 days and
`_receipts/` at 180. Verify them on every run of this act with the
`get-bucket-lifecycle-configuration` command in §2; a missing rule is a leak,
not an emergency.

**Manual fallback** (a rule was removed, or the archive must shrink now). It
deletes `archive/<stamp>/` folders older than N days, is a dry run unless given
`--apply`, never touches anything but stamp-named archive folders, and
**refuses** unless the newest receipt is under 48 hours old and records a
successful run. A broken backup must never let collection eat the only history.

```bash
cat > "$HOME/.mcr-r2/gc.sh" <<'SH'
#!/bin/zsh
set -u
APP=$1; DAYS=${2:-30}; APPLY=${3:-}; I="op://studio-agents/r2.$APP"
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_R2_ENDPOINT=$(op read "$I/endpoint")
export RCLONE_CONFIG_R2_ACCESS_KEY_ID=$(op read "$I/access-key-id-backup")
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$(op read "$I/secret-access-key-backup")
FRESH=$(date -u -v-48H +%Y-%m-%dT%H%M%SZ)
LAST=$(rclone lsf "r2:$APP-backup/_receipts/" 2>/dev/null | sort | tail -1)
if [[ -z "$LAST" || "${LAST%.json}" < "$FRESH" ]]; then echo "REFUSED: no run receipt newer than $FRESH (last: ${LAST:-none})"; exit 2; fi
if ! rclone cat "r2:$APP-backup/_receipts/$LAST" | grep -q '"rclone_exit":0'; then echo "REFUSED: last run $LAST did not succeed"; exit 2; fi
CUTOFF=$(date -u -v-${DAYS}d +%Y-%m-%dT%H%M%SZ)
echo "last good run: ${LAST%.json}; expiring archive folders older than $CUTOFF"
N=0
for d in $(rclone lsf --dirs-only "r2:$APP-backup/archive/"); do
  s=${d%/}
  [[ "$s" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$' ]] || { echo "  skip (not a stamp): $d"; continue; }
  [[ "$s" < "$CUTOFF" ]] || continue
  N=$((N+1))
  if [[ "$APPLY" == "--apply" ]]; then rclone purge "r2:$APP-backup/archive/$s" && echo "  deleted archive/$s"
  else echo "  would delete archive/$s"; fi
done
echo "$N folder(s) $([[ "$APPLY" == "--apply" ]] && echo deleted || echo 'would be deleted (dry run)')"
SH
zsh "$HOME/.mcr-r2/gc.sh" "$APP"            # dry run, 30 days
zsh "$HOME/.mcr-r2/gc.sh" "$APP" 30 --apply # only after reading the dry run
```

The `date -v` flags are BSD (macOS). Do not pipe the script into `grep`: a pipe
reports grep's exit status, and the refusal's exit 2 disappears. During
`--apply`, rclone logs one `Failed to read versioning status ... AccessDenied`
line per folder; the backup token has no bucket-level read and R2 has no
versioning, so the line is noise, and the `deleted` line after it is the result.

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
mirror is clean. The drill's archive expires with the rest.

## 6. Record

- Mark the app's backup as enabled in the R2 census in
  [`../../../modules/object-storage.md`](../../../modules/object-storage.md),
  with the date of the drill.
- The `r2.<app>` row in
  [`../../../modules/credential-inventory.md`](../../../modules/credential-inventory.md)
  already names the backup fields; nothing to add per app.
- Remove the helper scripts: `rm -rf "$HOME/.mcr-r2"`.
- Close the activity:
  `bin/agent-activity end --outcome "r2-backup <act> for <app>"`.

## Background — not needed to execute

R2's gaps against the S3 rules (no versioning, why this act exists), the tiers,
and the census: [`../../../modules/object-storage.md`](../../../modules/object-storage.md).
The first live run was on `moms-app` on 2026-09-26: two runs, archive held the
overwritten and deleted objects, restore brought the deleted one back, the
collection refusal fired on a simulated failed run, and all five isolation
probes were refused with `AccessDenied`.
