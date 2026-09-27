# Bucket Provision

## Status: Active

This is Steffon's `bucket-provision` SOP. It stands up **object storage for one
app** on **Cloudflare R2**: the dev/production bucket pair and the two
bucket-scoped tokens, in one sitting. Every app's storage lives in McRitchie
Studio's Cloudflare account; apps inherit it rather than holding an account
of their own (Alex, 2026-09-26). The conventions themselves live in
[`../../../modules/object-storage.md`](../../../modules/object-storage.md);
this file is the act that applies them.

Run it when a new app opts into storage at onboarding. The five apps that held
AWS S3 pairs were provisioned on R2 by this act on 2026-09-26; moving each one's
objects and config across is Wave 2 of the asset-library plan, one app per task,
not this act.

The AWS S3 procedure this replaced is in git history:
`git show 64d6f3a8:docs/agents/agents/steffon/sops/bucket-provision.md`.
Use it only to reason about the legacy S3 buckets until they are retired.

## What this act is NOT

- **It never deletes a bucket that holds objects.** Recreating a misplaced
  bucket is legal only after a list proves it empty.
- **It never touches the legacy S3 buckets.** Those still serve live apps
  until each app's Wave 2 cutover.
- **It never sets Heroku config.** An app starts reading R2 in its own
  cutover task, which writes the config vars and proves the read.
- **It never merges, deploys, or moves board tasks.**

## Entry

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity start --category Workflow --reason "bucket-provision <app>"
```

Inputs: the app slug (e.g. `rolio`) and Alex's yes to provisioning (the
onboarding prompt, or his direct ask).

## 1. Open the lane

Provisioning is **admin work**. The one credential it needs is the account-owned
Cloudflare token `cloudflare.studio.provision` in `studio-agents-admin`
(described in
[`../../../modules/credential-inventory.md`](../../../modules/credential-inventory.md)).
An admin token that is absent here is a setup gap on THIS MACHINE: `source
~/.zprofile.admin` when the file exists, `bin/setup-1pass-token --admin` (Alex,
once) when it does not.

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
export CF_TOKEN=$(op read "op://studio-agents-admin/cloudflare.studio.provision/api-token")
export CF_ACCOUNT=$(op read "op://studio-agents-admin/cloudflare.studio.provision/account-id")
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/tokens/verify" | grep -o '"status":"[a-z]*"'
# must print "status":"active"
```

Source it without a pipe: a pipeline runs `source` in a subshell, and the lane
then reads ABSENT while fully present.

## 2. Create the pair, mint the tokens, file the record

One script does all three so no secret ever reaches stdout: Cloudflare returns
each token's value once, and the script hashes it into the S3 secret and hands
both straight to `op item create` in an argv, never a shell or a print.

- **Buckets:** `<app>-dev` and `<app>-production`, location hint `enam`
  (eastern North America, nearest Heroku's US region). R2 buckets are private
  by default; there is no public-access block to set.
- **prod token** `r2-<app>-prod`: *Workers R2 Storage Bucket Item Write* on
  `<app>-production` only.
- **dev token** `r2-<app>-dev`: *Bucket Item Write* on `<app>-dev` plus
  *Bucket Item Read* on `<app>-production`. That read-only grant is what makes
  "QA reads prod, never writes it" a property of the token, not app discipline.
- **S3 credentials** derive from a token: access key id = the token's `id`,
  secret = SHA-256 of the token's `value` (Cloudflare's R2 token docs).
- **Record:** `r2.<app>` in `studio-agents`, fields `access-key-id-prod`,
  `secret-access-key-prod`, `access-key-id-dev`, `secret-access-key-dev`,
  `endpoint`, `region`. It refuses to run when that item already exists, so a
  re-run cannot mint an orphan second pair.

```bash
APP=<app-slug>
mkdir -p "$HOME/.mcr-r2" && cat > "$HOME/.mcr-r2/provision.py" <<'PY'
import hashlib, json, os, subprocess, sys, urllib.request, urllib.error
APP = sys.argv[1]
TOK, ACCT = os.environ["CF_TOKEN"], os.environ["CF_ACCOUNT"]
API = f"https://api.cloudflare.com/client/v4/accounts/{ACCT}"
ITEM_WRITE = "2efd5506f9c8494dacb1fa10a3e7d5b6"  # Workers R2 Storage Bucket Item Write
ITEM_READ = "6a018a9f2fc74eb6b293b0c548f38b39"   # Workers R2 Storage Bucket Item Read
VAULT, ITEM = "studio-agents", f"r2.{APP}"

def cf(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {TOK}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r: return json.load(r)
    except urllib.error.HTTPError as e: return json.load(e)

def res(bucket): return {f"com.cloudflare.edge.r2.bucket.{ACCT}_default_{bucket}": "*"}

if subprocess.run(["op", "item", "get", ITEM, "--vault", VAULT], capture_output=True).returncode == 0:
    sys.exit(f"{ITEM} already exists in {VAULT}; refusing to mint a second pair")
for env in ("dev", "production"):
    d = cf("POST", "/r2/buckets", {"name": f"{APP}-{env}", "locationHint": "enam"})
    if not d.get("success"): sys.exit(f"bucket {APP}-{env}: FAILED {d.get('errors')}")
    print(f"bucket {APP}-{env}: created")
policies = {
    "prod": [{"effect": "allow", "permission_groups": [{"id": ITEM_WRITE}], "resources": res(f"{APP}-production")}],
    "dev": [{"effect": "allow", "permission_groups": [{"id": ITEM_WRITE}], "resources": res(f"{APP}-dev")},
            {"effect": "allow", "permission_groups": [{"id": ITEM_READ}], "resources": res(f"{APP}-production")}],
}
fields = []
for env, pol in policies.items():
    d = cf("POST", "/tokens", {"name": f"r2-{APP}-{env}", "policies": pol})
    if not d.get("success"): sys.exit(f"token r2-{APP}-{env}: FAILED {d.get('errors')}")
    t = d["result"]
    fields += [f"access-key-id-{env}[concealed]={t['id']}",
               f"secret-access-key-{env}[concealed]={hashlib.sha256(t['value'].encode()).hexdigest()}"]
    print(f"token r2-{APP}-{env}: minted")
fields += [f"endpoint[text]=https://{ACCT}.r2.cloudflarestorage.com", "region[text]=auto"]
p = subprocess.run(["op", "item", "create", "--vault", VAULT, "--category", "API Credential",
                    "--title", ITEM, *fields], capture_output=True, text=True)
if p.returncode != 0: sys.exit(f"1Password write FAILED: {p.stderr.strip()[:200]}")
print(f"filed {ITEM} in {VAULT}")
PY
python3 "$HOME/.mcr-r2/provision.py" "$APP"
```

The two permission-group ids are Cloudflare's, stable across accounts; re-read
them with `GET /accounts/<id>/tokens/permission_groups` if a mint is refused
naming one. A failure after the first token mints leaves that token live in
the dashboard (**Manage Account → Account API Tokens**, named `r2-<app>-*`):
revoke it before re-running.

## 3. Verify — positive and negative

Every probe runs with the minted S3 keys against the R2 endpoint, and the
negative probes are the point: a provision whose dev token was never refused a
production write is not verified.

```bash
cat > "$HOME/.mcr-r2/verify.sh" <<'SH'
#!/bin/zsh
APP=$1; I="op://studio-agents/r2.$APP"
EP=$(op read "$I/endpoint")
PID=$(op read "$I/access-key-id-prod"); PSEC=$(op read "$I/secret-access-key-prod")
DID=$(op read "$I/access-key-id-dev");  DSEC=$(op read "$I/secret-access-key-dev")
KEY="_probe/r2-verify-$(date +%s).txt"; BODY=$(mktemp); ERR=$(mktemp); echo probe > "$BODY"
s3()  { local id=$1 sec=$2; shift 2; AWS_ACCESS_KEY_ID=$id AWS_SECRET_ACCESS_KEY=$sec AWS_DEFAULT_REGION=auto \
        aws s3api --endpoint-url "$EP" "$@" >/dev/null 2>"$ERR"; }
FAILS=0
ok()  { if "$@"; then echo "  PASS"; else echo "  FAIL: $(head -c 160 "$ERR")"; FAILS=$((FAILS+1)); fi; }
bad() { if "$@"; then echo "  VIOLATION (succeeded)"; FAILS=$((FAILS+1)); else echo "  PASS (refused)"; fi; }
echo "prod key writes production";  ok  s3 $PID $PSEC put-object --bucket $APP-production --key $KEY --body "$BODY"
echo "prod key reads production";   ok  s3 $PID $PSEC get-object --bucket $APP-production --key $KEY /dev/null
echo "prod key cannot touch dev";   bad s3 $PID $PSEC put-object --bucket $APP-dev --key $KEY --body "$BODY"
echo "dev key writes dev";          ok  s3 $DID $DSEC put-object --bucket $APP-dev --key $KEY --body "$BODY"
echo "dev key reads production";    ok  s3 $DID $DSEC get-object --bucket $APP-production --key $KEY /dev/null
echo "THE LAW: dev key cannot write production"; bad s3 $DID $DSEC put-object --bucket $APP-production --key $KEY.dev --body "$BODY"
echo "dev key cannot delete production";         bad s3 $DID $DSEC delete-object --bucket $APP-production --key $KEY
echo "cleanup"; ok s3 $PID $PSEC delete-object --bucket $APP-production --key $KEY
                ok s3 $DID $DSEC delete-object --bucket $APP-dev --key $KEY
rm -f "$BODY" "$ERR"; echo "$APP: $FAILS failure(s)"; exit $FAILS
SH
zsh "$HOME/.mcr-r2/verify.sh" "$APP"   # must end "<app>: 0 failure(s)"
```

A fresh token can take a few seconds to propagate; one `AccessDenied` on the
very first positive probe is worth a single re-run before it is a finding.

## 4. Record

- Add the pair to the R2 census in
  [`../../../modules/object-storage.md`](../../../modules/object-storage.md).
- Add the `r2.<app>` row to
  [`../../../modules/credential-inventory.md`](../../../modules/credential-inventory.md).
- Remove the helper scripts: `rm -rf "$HOME/.mcr-r2"`. They hold no secret,
  but a stale copy drifts from this page.
- Close the activity:
  `bin/agent-activity end --outcome "provisioned <app> R2 pair + tokens"`.

## Decline path

When the onboarding prompt gets a "no", record the opt-out in the app's README
(one line: "no object storage; run `bucket-provision` if that changes") and
stop. Do not create empty buckets on spec.

## Background — not needed to execute

Rule set, credential tiers, the R2 gaps (no versioning) and the legacy S3
posture: [`../../../modules/object-storage.md`](../../../modules/object-storage.md).
Why an admin lane is meant to hold admin credentials:
[`../../../modules/credentials.md`](../../../modules/credentials.md).
