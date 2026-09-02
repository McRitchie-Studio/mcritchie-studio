# Bucket Provision

## Status: Active

This is Steffon's `bucket-provision` SOP. It stands up **object storage for one
app**: the dev/production bucket pair, their safety posture, and the two
per-app IAM users — in one sitting, to the standards Mr. McRitchie approved
2026-09-01. The conventions themselves live in
[`../../../modules/object-storage.md`](../../../modules/object-storage.md);
this file is the act that applies them.

Run it when a new app opts into storage at onboarding, or when an existing app
graduates off the shared `mcritchie-s3` identity.

## What this act is NOT

- **It never deletes a bucket that holds objects.** Recreating a misplaced
  bucket is legal only after `list-objects-v2` proves `KeyCount` 0.
- **It never touches the studio/turf public-read policies.** Those buckets
  serve live apps; changing their posture is ladder work, not provisioning.
- **It never merges, deploys, or moves board tasks.**

## Entry

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity start --category Workflow --reason "bucket-provision <app>"
```

Inputs: the app slug (e.g. `rolio`), its entity tag (e.g. `mcritchie-studio`),
and Mr. McRitchie's yes to provisioning (the onboarding prompt, or his direct
ask).

## 1. Open the lane

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
export AWS_ACCESS_KEY_ID=$(op item get AWS --vault studio-agents-admin --fields label=access-key --reveal)
export AWS_SECRET_ACCESS_KEY=$(op item get AWS --vault studio-agents-admin --fields label=secret-access-key --reveal)
export AWS_DEFAULT_REGION=us-east-2
aws sts get-caller-identity   # must answer arn:...:user/studio-agents-admin
```

A refused `op` read here usually means the shell skipped
`~/.zprofile.admin`, or the 1Password daily quota is spent — check
`op service-account ratelimit` before escalating.

## 2. Create the pair

```bash
APP=<app-slug>; ENTITY=<entity-tag>
for env in dev production; do
  b="$APP-$env"
  aws s3api create-bucket --bucket "$b" \
    --create-bucket-configuration LocationConstraint=us-east-2
  aws s3api put-public-access-block --bucket "$b" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$b" \
    --tagging "TagSet=[{Key=app,Value=$APP},{Key=env,Value=$env},{Key=entity,Value=$ENTITY}]"
done
aws s3api put-bucket-versioning --bucket "$APP-production" \
  --versioning-configuration Status=Enabled
```

Private, tagged, production versioned, dev not. Encryption is the account
default (SSE-S3); ACLs are disabled fleet-wide, so grant nothing per-object.

## 3. Mint the per-app users

Each app gets two IAM users under path `/mcr/` — the path is what keeps them
inside `studio-agents-admin`'s reach and outside everything else's. The dev user's
read-only-prod grant is what makes "QA reads prod, never writes it" a law of
IAM instead of a hope.

```bash
for env in prod dev; do
  aws iam create-user --user-name "mcr-$APP-$env" --path /mcr/ \
    --tags "Key=app,Value=$APP"
done

aws iam put-user-policy --user-name "mcr-$APP-prod" --policy-name bucket-access \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucket\"],
     \"Resource\":[\"arn:aws:s3:::$APP-production\",\"arn:aws:s3:::$APP-production/*\"]}]}"

aws iam put-user-policy --user-name "mcr-$APP-dev" --policy-name bucket-access \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucket\"],
     \"Resource\":[\"arn:aws:s3:::$APP-dev\",\"arn:aws:s3:::$APP-dev/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
     \"Resource\":[\"arn:aws:s3:::$APP-production\",\"arn:aws:s3:::$APP-production/*\"]}]}"

# Mint WITHOUT printing: `create-access-key` writes the secret to stdout, and
# stdout is the session transcript (AGENTS.md First Rules: "Do not print
# secrets"). Capture to owner-only files, read them in step 4, shred in step 6.
umask 077
for env in prod dev; do
  aws iam create-access-key --user-name "mcr-$APP-$env" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text \
    > "$HOME/.mcr-$APP-$env.key"
done
```

## 4. Store the keys — the one manual seam

The admin service account's vault grant is **read-only**, so this SOP cannot
write 1Password items. Each pair is in `$HOME/.mcr-$APP-<env>.key` from step 3
(id, then secret). Route it to its stores without printing it into a transcript:

- **Deployed app:** set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` on the
  Heroku app directly (`heroku config:set`, deployer lane) — prod key on the
  production app, dev key on QA.
- **1Password record:** item `agent.<app>.aws` in `studio-agents` (fields
  `access-key-id-prod`, `secret-access-key-prod`, `access-key-id-dev`,
  `secret-access-key-dev`) — created by the operator or any lane whose vault
  grant can write; hand over the values through a private channel, never chat.
- Local dev reads the dev credential from 1Password, never a committed file.

## 5. Verify — positive and negative

```bash
read -r PROD_ID PROD_SECRET < "$HOME/.mcr-$APP-prod.key"
read -r DEV_ID DEV_SECRET < "$HOME/.mcr-$APP-dev.key"

# each minted key answers as itself (repeat with $DEV_ID/$DEV_SECRET)
AWS_ACCESS_KEY_ID=$PROD_ID AWS_SECRET_ACCESS_KEY=$PROD_SECRET \
  aws sts get-caller-identity

# THE law: the dev key must FAIL to write production
AWS_ACCESS_KEY_ID=$DEV_ID AWS_SECRET_ACCESS_KEY=$DEV_SECRET \
  aws s3api put-object --bucket "$APP-production" --key probe.txt --body /dev/null \
  && echo "VIOLATION — dev key wrote prod; fix the policy before handing off" \
  || echo "read-only prod confirmed"
```

A provision whose negative probe never ran is not verified — the routing rule
is the point of the whole design.

## 6. Record

- Add the pair to the fleet census in
  [`../../../modules/object-storage.md`](../../../modules/object-storage.md).
- Describe the new 1Password item in
  [`../../../modules/credential-inventory.md`](../../../modules/credential-inventory.md).
- Shred the key files: `rm -P "$HOME/.mcr-$APP-prod.key" "$HOME/.mcr-$APP-dev.key"`.
- Close the activity:
  `bin/agent-activity end --outcome "provisioned <app> buckets + users"`.

## Decline path

When the onboarding prompt gets a "no", record the opt-out in the app's README
(one line: "no object storage; run `bucket-provision` if that changes") and
stop. Do not create empty buckets on spec.

## Background — not needed to execute

Approved rule set, credential tiers, legacy shared-identity migration, and the
public-read exceptions: [`../../../modules/object-storage.md`](../../../modules/object-storage.md).
The 2026-09-01 fleet audit that produced these standards found six of nine
buckets world-readable (including the empty Industries pair now flipped
private) and zero versioning anywhere — the census table records the after
state.
