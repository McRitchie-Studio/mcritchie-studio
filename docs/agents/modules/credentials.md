# Credentials

Credential docs are split into two layers:

- This file defines how agents may access credentials.
- [`credential-inventory.md`](credential-inventory.md) lists known item names and references without exposing secret values.

## Contract

- Never print secrets into the terminal or transcript.
- Use `/opt/homebrew/bin/op` directly for targeted reads.
- Prefer repo scripts that write or consume secrets without echoing them.
- Do not scan vaults broadly unless Alex explicitly asks.
- Do not edit agent tool permissions or `.claude/settings*.json` to gain credential access.
- If a permission is missing, report the exact vault, item, and operation needed instead of inventing a workaround.

## Commands that print what they touch

Before running anything near a credential, ask what it prints. Each of these has
put a live secret in a transcript:

- **`heroku releases:info <v>` prints every config var in plaintext.** For a
  release's log use `heroku releases:output <v>`.
- **`heroku config:set VAR=…` echoes the value it set**, multi-line secrets
  included. Run it as `heroku config:set … >/dev/null 2>&1; echo "exit $?"`.
- **`heroku config:get` cannot verify anything**: absent, empty and a failed read all
  print one bare newline. Test presence with a control:
  `heroku config --json -a <app> | jq 'length'` (0 means the read failed), then
  `jq '(.NAME // "") != ""'`.
- **Any "only stderr" redirect** uses the brace-group form in
  [`../system/coding-standards.md`](../system/coding-standards.md#shell-zsh-on-macos).

**Hunting a leak must not repeat it.** Use a slice of the live variable as the grep
needle (`needle="${SECRET:200:60}"`), report paths and counts only, and tell a real
token from a format example by its length. Once printed, a credential is
compromised: rotate first, then clean the copies.

## Local env files hold development keys

**No local `.env` holds a production `SECRET_KEY_BASE`.** Rails 8.1 development
reads the env key (measured 2026-10-06: the app's key and the env key share a
digest), so a production key on disk signs cookies, magic links and API tokens
that production accepts. Until that day every primary and desk held the hub's,
because `bin/ecosystem-build` restored each primary's `.env` from the production
app's config and `bin/agent-worktree new` copied it into every desk.

Both writers now generate instead (`bin/lib/dev_secret_key.rb`): the restore drops
the production key and writes a fresh one, and a desk cut gives its copy of `.env`
its own key. Check and repair with:

```bash
bin/dev-secret-key scan    # every primary and desk vs each production app's digest; exit 1 = a match
bin/dev-secret-key fix     # the same, then a fresh dev key in each flagged file
```

It prints paths and 8-char SHA-256 prefixes, never a value, reads production
digests with `heroku config --json` (read-only), and exits 4 when it could read no
production digest, because a scan with nothing to compare against proves nothing.
No local flow needs the production key: Turf's managed-wallet encryption keys off
`credentials.secret_key_base` (the master-key file), not the env value, and board
tokens are minted by production from `AGENT_API_SECRET`.

### Production-only keys

**The same scan covers the deny list**, `DevSecretKey::PRODUCTION_ONLY_KEYS` in
`bin/lib/dev_secret_key.rb`, the one place it lives: `SOLANA_ADMIN_KEY` (first),
`CDP_API_KEY_ID`, `CDP_API_KEY_SECRET`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `RESEND_API_KEY`, `GITHUB_TOKEN`,
`MANAGED_WALLET_ENCRYPTION_KEY`, `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS`,
`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` and the three
`ACTIVE_RECORD_ENCRYPTION_*` names. The 2026-10-06 sweep found the
old restore had copied each of them out of production `heroku config` into the
primaries and every desk. `bin/ecosystem-build` now pipes its restore
through `bin/dev-secret-key filter` and writes nothing when it cannot run the
filter, `bin/agent-worktree` drops them from the `.env` it copies into a new desk,
and `scan` reports a production value for any listed key (exit 1); `fix` removes
it. "Production" excludes the QA apps (`DevSecretKey::QA_HEROKU_APPS`): local turf
shares QA's managed-wallet key on purpose, so a QA value is reported `dev` and
left alone.

| Key | Why local dev does without it |
|---|---|
| `SOLANA_ADMIN_KEY` | mainnet `VaultState` signer (`8K81…`) and fee payer; turf QA holds the same key |
| `CDP_API_KEY_*` | the production Coinbase key; only the ramp flows call it |
| `AWS_*` | the production IAM key; local storage runs on R2 with QA keys (`.env.development`) |
| `RESEND_API_KEY` | production mail; local stacks capture mail (`LOCAL_EMAIL_CAPTURE=1`) |
| `GITHUB_TOKEN` | the hub's static fallback PAT; it answered 401 on 2026-10-06 |
| `MANAGED_WALLET_ENCRYPTION_KEY(_PREVIOUS)` | mainnet's opens every custodial mainnet wallet; development falls back to `secret_key_base` |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` | live Stripe on `turf-monster-mainnet`; local runs test mode |
| `ACTIVE_RECORD_ENCRYPTION_*` | production's open every stored fact value and the stored TikTok connection; development uses the fixed keys in `config/environments/development.rb` |

Kept by design: `RAILS_MASTER_KEY` and `AGENT_API_SECRET`.

⚠ **`fix` removing `SOLANA_ADMIN_KEY` stops turf's local devnet admin signing**:
the devnet `VaultState` seats only `8K81…`, Alex and Mason, so local dev has no
devnet-only signer until one is seated (turf-monster
`docs/qa-signing-key-rotation.md`, "What this ceremony does not fix").

## How a soul logs in to the board

The board API takes two bearers (design:
[`../system/agent-sessions-design.md`](../system/agent-sessions-design.md)).

- **An agent session.** `bin/task begin` logs the desk's soul in to the task it
  claimed (`POST /api/v1/agent_sessions`, presented with the machine's harness
  key, or with the shared token on a machine that holds none) and keeps
  the session token in `agent-session.json` inside the desk's git directory,
  owner-only, where no commit can reach it, with the harness session (Claude or
  Codex) that ran `begin`. Only that harness session presents it: anyone else running
  `bin/task` in the desk, a reviewer included, uses the shared token. A studio session is scoped to that task,
  lives while the task is `building` or `submitted`, and expires after 24 hours. Its
  soul is the actor on every board write it makes; an `actor` or `by` param is
  ignored. It may write only its own task, and a release endpoint answers 403.
- **A reviewer's session.** A review claim taken with the harness key or the
  shared token
  (`bin/task claim-next-review --agent <soul>`, `bin/task review-claim acquire`)
  logs that reviewer in to the claimed task, when the soul is in the reviewer pool
  and outside the task's author set. The claim's response carries the token, and
  the command keeps it in `agent-review-sessions/<task>.json` inside the git
  directory of the checkout it ran in, one file per claimed task. The harness
  session that claimed presents it on `bin/task` writes to that task from that
  checkout, ahead of a desk's own login. It lives while the task is `submitted`
  and the claim is live: releasing the claim, a new holder, or a resubmission
  revokes it, and a lapsed claim or a task at `reviewed` or blocked answers 401.
  A light spawned in the claiming harness session writes as the claiming soul.
- **Transitions under a session.** A move to `reviewed` from `designed`,
  `building` or `submitted`, and a block of a `submitted` task, take a reviewer's
  session (or an admin's) whose soul is outside the author set; any stage to
  `archived` takes an admin session. Anything else answers 403 naming the
  transition. `reviewed` to `assembled` and `assembled` to `shipped` are unchecked.
  The stage events (`events/<stage>/complete` and `/fail`) are checked the same way.
  `bin/task` retries on the shared token after a 401, never after this 403. A
  reviewer who zapped the PR is an author: release the claim (`bin/task
  review-claim release <slug>`), then make the move, which rides the shared token
  while that is accepted. With an admin login held, an admin outside the author
  set makes it instead: `TASK_AS_ADMIN=1 bin/task move <slug> reviewed`.
  `bin/task` never offers a desk's studio login on a move to `archived`: that
  move rides the shared token while it is accepted, or the admin login with
  `TASK_AS_ADMIN=1 bin/task move <slug> archived`.
- **Acting as an admin.** `TASK_AS_ADMIN=1` makes one `bin/task` run present the
  admin login this harness session holds, on every call. The board records the
  admin soul as the actor. A run that holds no admin login, or whose login the
  board ended, stops and names how to log in; it never falls back. No command
  presents the admin login unasked, because every agent a harness spawns can read
  it.
- **The shared token** from `AGENT_API_SECRET` (`POST /api/v1/auth`). It still works
  everywhere it did, with each use logged as `[agent-auth] legacy` (naming
  the dropped desk session when a desk fell back from one) and counted in the
  legacy-use census, so Turf Monster's two endpoints, installed hooks and older
  checkouts keep running. It stops writing only after the census reads zero
  ([The legacy-use census](#the-legacy-use-census)).

### The harness key

A harness key is one machine's credential for minting logins. It mints the studio
login at a task claim and at a review claim, and posts login requests; every other
endpoint answers it 403. The operator grants it once per machine:

```bash
bin/harness-key request                 # prints a login-… slug; the board row reads "Harness key · <machine>"
bin/harness-key collect --code <code>   # with the row's one-time code; or `collect` alone after the Approve tap
bin/harness-key status                  # the slug, the machine and the key's length; whether the board accepts it
```

The key is kept in `<projects>/.agents/harness-key.json`, owner-only, and no
command prints it. It has no expiry: `bin/rails agent_sessions:keys` lists every
key without a value, and `bin/rails agent_sessions:revoke SLUG=<sess-…>` ends one
at once. A machine with no key, or whose key was revoked, mints with the shared
token and says so.

### Turf Monster's runtime key

Turf Monster's two hub calls (`GET /api/v1/athletes`, `POST /api/v1/game_recaps`)
take a client runtime key that reaches those two endpoints and nothing else. The
production hub mints it:

```bash
bin/rails agent_sessions:grant_runtime_key SOUL=turf-monster LABEL=turf-production
```

**Production only.** The key is a row on the hub that minted it, and
`turf-monster-mainnet` is the Turf app that calls the hub. `turf-monster-qa`
holds neither `STUDIO_RUNTIME_KEY` nor `AGENT_API_SECRET`, so it makes no hub
call (`Studio::HubCredential.configured?` in turf-monster) and takes no key.

In a local shell the task prints the key on stdout and its one-line notice on
stderr. Through `heroku run` a one-off dyno returns both streams on stdout, so
the capture holds the notice and the key. The key is the one line with no space
in it, and the notice states its length. Keep that line, check that exactly one
line was kept, and set it as `STUDIO_RUNTIME_KEY` on `turf-monster-mainnet`
under the [`credential-rotation`](../agents/steffon/sops/credential-rotation.md)
SOP, never reading it. Each run mints a new key: revoke one that was not kept
with `bin/rails agent_sessions:revoke SLUG=<sess-…>`.

Turf presents the key when the variable is set and
exchanges `AGENT_API_SECRET` while it is not. A refused key fails the call and
does not fall back, so a wrong key shows as a failed sync or a
`recap_push_failed` anomaly.

### The legacy-use census

Every request the shared token authenticates is counted per day, by endpoint and
by the script that called (`X-Agent-Caller`; a request that names none counts as
`unlabelled`). The count holds no token. An admin reads it from a hub shell:

```bash
bin/rails agent_auth:legacy_census DAYS=7
```

The first line gives the total and the count outside the mint doors (the exchange
of the secret and the requests that mint a login, which the secret keeps). A line
marked `*` is a use outside them. The shared token stops writing only after that
count reads zero on production for the period Alex chooses.

### Hooks and narration

`bin/agent-activity`, the capture hook, `bin/session-insights` and the release
conductor's claim present a login the harness session holds and fall back to the
shared token only when the board answers the login 401. Narration presents a
login only when its soul is the lane the call declares. `AGENT_LEGACY_TOKEN=off`
is the degraded mode: the shared token is neither read nor minted, a call with a
login is made under it, and a call with none is not made, so nothing is recorded.

Admin sessions (Steffon, Xan) are unscoped within the admin tier and expire after
8 hours. `bin/agent-activity heartbeat steffon|xan` posts an admin login request
with the shared token and prints its server-issued `login-…` slug. The board
(`/tasks`, `/deployments`) shows an admin each open request with that slug: the
operator answers only the row whose slug the agent printed, because the soul and
the session id on a row are whatever the poster sent. He grants it one of two
ways inside the ten-minute `admin_login` window (`config/release_builder.yml`):

- **The launch code.** The row carries a one-time code. The operator puts the
  code in the launch phrase, and the agent runs `bin/agent-activity heartbeat
  <soul> --code <code>`, which grants and collects in one call. The code is bound
  to that request, is spent by one grant, and lapses with the window. A wrong
  code answers 403 with the attempts left; the fifth refuses the request. A
  phrase with no code grants nothing.
- **The Approve tap** on the same row. `Decline` refuses the request.

One harness session holds one open request per soul: a second post under the
same session id answers 409 unless it presents the open request's collect key. A
soul gets three requests inside one window (429 after that); a Decline frees its
slot. That bounds wrong codes at fifteen per soul per window.

After an Approve tap the harness session that asked collects the token once
(`heartbeat <soul>` again, or `--wait <seconds>` to keep trying) and keeps it in
`.agents/sessions/<harness session>.admin-login`, owner-only; it is never printed.
`heartbeat --clear`, a heartbeat as the other admin soul and the session's end
revoke it. A request that lapsed or was
refused mints nothing, and the collect answers 410 with the reason. `bin/task`
presents this token when asked (`TASK_AS_ADMIN=1`), `bin/tiktok-draft` presents
it to the board that granted it, and the release conductor's claim presents it.

A shell on the hub is the third grant, for when the board cannot grant. The task
prints the token on stdout and nothing else, so take it into the environment
without reading it, and never paste or file it:

```bash
export AGENT_ADMIN_SESSION_TOKEN="$(bin/rails agent_sessions:grant_admin)"   # SOUL=steffon, HOURS=1 to narrow it
```

Most admin-tier endpoints still pass the shared token. An endpoint declared
`require_admin_session_only` does not: today that is the TikTok draft create,
which `bin/tiktok-draft` reaches with the board's admin login or the variable
above. Every refusal answers
401 (the session ended: revoked, expired, or the task moved on) or 403 (tier or
scope) with the reason. `GET /api/v1/agent_sessions/current` says who a bearer is;
`DELETE` on the same path logs out.

The facts API (`/api/v1/facts`, `bin/fact`) takes an agent session only: the
shared token answers 401, a client session 403. A studio session reads and writes
ordinary facts; sensitive facts need the admin session.

## Fact encryption keys

`Fact#value` is encrypted with Active Record Encryption, and so is the stored
TikTok connection (`TiktokConnection#refresh_token`). Production and QA read
three config vars, one set per app. Both sets were filed on 2026-10-08 through
[`credential-filing`](../agents/steffon/sops/credential-filing.md), in the
`studio-applications` vault: `active-record-encryption.studio.applications`
(production, `mcritchie-studio`) and
`active-record-encryption.studio-qa.applications` (QA, `mcritchie-studio-qa`),
fields `primary-key`, `deterministic-key` and `key-derivation-salt`. As of
2026-10-08 each app's config holds all three names, each value matched its
vault field by digest, and production had no stored fact when they were set
([`credential-inventory.md`](credential-inventory.md)).

| Config var | Holds |
|---|---|
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | the key fact values are encrypted with |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | the key for deterministic attributes; none is declared, Rails takes the set |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | the salt both keys are derived with |

- Without them the app boots, `/api/v1/facts` answers 503 naming the vars, and
  the person page says facts cannot be read.
- **Recovery, when an app's config has lost them and its 1Password item is
  intact** (a restored app that carries an existing database is this case): set
  the same three values back from that app's own item, field `primary-key` to
  `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `deterministic-key` to
  `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` and `key-derivation-salt` to
  `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`, through
  [`credential-filing`](../agents/steffon/sops/credential-filing.md), with no
  command that prints a value. Never generate a new set for an app that holds
  stored values: a new set makes every one of them unreadable.
- **A fresh app with an empty database** gets its own new set, generated with
  `bin/rails db:encryption:init` and filed under its own new item. Never file
  over an existing item: that overwrites the filed copy of a set some database
  still needs.
- **To confirm an app holds them, ask by name, never by printing a value.** Per
  name, `heroku config --json --app <app> | jq '(.ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY // "") != ""'`
  answers `true` only when the name is present and non-empty; the same
  expression on an absent name answers `false`, which is the control
  ([`house-burn-down.md`](../system/house-burn-down.md), the hub `.env` block,
  where the idiom comes from).
- Losing the primary key or the salt from both the app's config and its item
  makes every stored fact value unreadable, and nothing recovers one. The
  stored TikTok connection becomes unreadable too; that one recovers by signing
  in again at `/admin/tiktok/connect`.
- These keys are not rotated on a cadence, and none is changed in place. A
  forced change (a compromise) loses the stored facts and needs a TikTok
  sign-in, so it is a recovery event, not a rotation.
- The two apps hold different sets. Never copy production's set to QA or the
  reverse.
- Development and test use fixed keys from `config/environments/`, which guard
  no real data. No key is committed for production, and the production values
  are on the [production-only list](#production-only-keys), so no restore copies
  them into a local `.env`.

## 1Password CLI quirks

- `op item delete` (and `--archive`) refuses a Password-category item whose password
  is empty (`Password item requires ps value`): set a placeholder with `op item edit`
  first.
- `op item create "<label>[file]=<path>"` rejects a label with more than one period.

## Personal data in a public repo

**`mcritchie-studio` and its sibling repos are PUBLIC.** Confirm rather than
assume — `gh api repos/<owner>/<repo> --jq .visibility` — because the rule below
only binds for a public one, and the answer is not visible from a working copy.

Before committing a personal email address, phone number, home address, or
anyone's full name **other than the ecosystem's own public identities**, stop and
route it to 1Password instead. It is not a secret in the credential sense, which
is exactly why it slips through: there is nothing to redact, no token to rotate,
and every existing guard is looking for something that looks like a key.

**The trigger is publication, not merge.** A pushed branch on a public repo is
already world-readable, and a force-push does not retract it — the orphaned
commit stays reachable by SHA. So the check belongs BEFORE `git push`, not before
merge, and "we can strip it in a follow-up" is not a remedy.

Already-public identities are fine and need no ceremony: the git author address,
a business domain's own contact, an open-source author's address in a vendored
file. What this rule is about is **third parties who did not choose to be
published** — most often family.

## 1Password Service Account

Agent shells use `OP_SERVICE_ACCOUNT_TOKEN` from `~/.zprofile`, installed by:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/setup-1pass-token
```

**Two lanes, two vaults, two tokens.** `bin/lib/op_vaults.rb` is the ONE place
that maps a lane to its vault and token; no other file should name a vault.

| Lane | Vault (default) | Token variable | Loaded where |
|------|-----------------|----------------|--------------|
| `agent` — build, review, merge | `studio-agents` | `OP_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile` — every shell |
| `deployer` — ship, deploy | `studio-agents-admin` | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile.admin` — opt-in |

Install the admin one with `bin/setup-1pass-token --admin`; ship lanes then
`source ~/.zprofile.admin`. It is deliberately NOT auto-loaded, so an ordinary
agent shell cannot read the admin vault (`bin/lib/op_vaults.rb#LANES`). Not
caching a deployer token is a separate mechanism
(`bin/gh-token#CACHEABLE_IDENTITIES`). A
machine whose vaults are named differently sets `MCR_OP_VAULT_AGENT` /
`MCR_OP_VAULT_ADMIN` rather than editing any script.

A `bin/gh-token --identity deployer` that fails naming
`OP_ADMIN_SERVICE_ACCOUNT_TOKEN` is the isolation WORKING — do not route around
it by granting the agent token access to the admin vault.

### An admin lane is MEANT to hold admin credentials

Everything above says what an ordinary agent shell **cannot** do. It never says
what the admin lanes **can**, and that omission has a cost: a lane entitled to
admin access reads its own credential failure as a locked door and escalates,
rather than fixing a machine it is entitled to fix.

So state the other half. **`production-deploy` is an admin act**, and the agent
running it holds the `deployer` lane — the admin token and the
`github.mcritchie-admin` identity — exactly as a build lane holds the agent
one. Admin credentials are withheld from **ordinary shells**, not from the admin
lanes.

That makes the decision rule one line: **on an admin lane, an admin credential
that is absent or refused is a SETUP gap on this machine — not a sign that the
lane is closed to you.** WHICH gap decides who closes it, and
`OpVaults#diagnose` already prints the right one rather than guessing:

| State of the machine | Remedy | Whose |
|---|---|---|
| `~/.zprofile.admin` on disk, absent from THIS shell | `source ~/.zprofile.admin`, then retry | **yours** |
| no `~/.zprofile.admin` at all — never provisioned | `bin/setup-1pass-token --admin`, once | **Alex's** — the install reads the token off his clipboard |

The second row is the **only** credential step on either lane that is his
([`token-session.md`](token-session.md) → *The one honest escalation*). Never
reach for it without testing the first: handing a deploy back to him because a
credential failed is the operator toil `AGENTS.md` forbids.

#### Two ways the CHECK lies

**1. A pipe runs `source` in a subshell.** Every stage of a pipeline is its own
process, so the export lands in a child that exits before the next command reads
it — the token measures ABSENT while being perfectly present:

```bash
source ~/.zprofile.admin 2>&1 | head -3    # ✗ the export dies with the subshell
source ~/.zprofile.admin                   # ✓
[ -n "$OP_ADMIN_SERVICE_ACCOUNT_TOKEN" ] && \
  echo "admin token: set (${#OP_ADMIN_SERVICE_ACCOUNT_TOKEN} chars)"
```

Report a token by LENGTH, never by value — and never probe with
`echo "${VAR:-absent}"`. The `:-` form substitutes only when the variable is
EMPTY, so the one case it is meant to detect is the case that prints the secret.

**2. A bare `op` tests the AGENT lane, whatever you sourced.** `op` takes its
credential from `OP_SERVICE_ACCOUNT_TOKEN` and no other variable, so a direct
read in a shell that HAS sourced `~/.zprofile.admin` still authenticates as the
agent:

```text
$ op item get github.mcritchie-admin --vault studio-agents-admin --fields label=app-id
[ERROR] "studio-agents-admin" isn't a vault in this account.
```

That answer is about the token in hand — not about the vault, and not about your
grant. It is also indistinguishable by text from the same error raised by a
genuinely wrong vault name, which the 2026-09-02 entity-first rename left behind
in code still asking for a bare `agents`. The `bin/` stack never hits this
because `OpVaults.op_env` swaps the lane's token in for the child `op`; do the
same by hand for a direct read:

```bash
OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN" \
  op item get github.mcritchie-admin --vault studio-agents-admin \
  --fields label=app-id >/dev/null && echo "admin vault: readable"
```

### Who spent the quota

The daily read cap is **1,000, account-wide** — shared by every service account
and every lane — so one careless loop stops the whole ecosystem. Every `op`
invocation the `bin/` stack makes is therefore recorded, and the question is a
query rather than an investigation:

```bash
bin/op-reads                 # by calling command, last 24h
bin/op-reads --by context    # by fan-out, when MCR_OP_METER_CONTEXT was exported
bin/op-reads --tail 40       # the raw rows
```

| Piece | What it is |
|---|---|
| `bin/lib/op_meter.rb` | the Ruby half — `OpMeter.popen` wraps the call; `bin/lib/agent_api.rb`, `bin/lib/task_board.rb`, `bin/gh-token` use it |
| `bin/lib/op-meter.sh` | the shell half — `op_metered <bin> <args…>`, sourced by `bin/secret`, `bin/gh-app-git-credential`, `bin/ecosystem-build`, `bin/setup-1pass-token` |
| `<projects>/.agents/op-reads.log` | the append-only log: timestamp, calling command, action, outcome, seam, pid, context |
| `bin/op-reads` | the read-only query |

**New `op` call sites go through the wrapper.** That is the whole contract — a
bare `op` is invisible to the log, and an unattributed read is the defect this
closes. Metering is best-effort in both halves: it never raises, never changes
the child's exit status, and never costs a read of its own, so a consumer's
fallback for an absent or rate-limited `op` is untouched.

⚠️ `op service-account ratelimit` **itself costs a read** — do not poll it.
There is deliberately **no alarm or budget threshold**; once spend is
attributable it is findable.

Verify:

```bash
/opt/homebrew/bin/op whoami
```

Expected user type: `SERVICE_ACCOUNT`.

Default access is the AGENT vault (`studio-agents`). The ADMIN vault (`studio-agents-admin`) is granted to a SEPARATE service account, never added to this one — that separation is what stops a build lane MINTING an admin credential; the 1Password read is the step it blocks, which is narrower than the claim that a build lane can never hold one (see above). Additional vaults should be granted deliberately for a role or task, such as a DevOps-specific vault for AWS credentials.

## GitHub (`gh` / `git`)

> **Operating knowledge — architecture, the two identities, auth recovery,
> symptom→fix, and usage in the workflow — now lives in
> [`source-control.md`](source-control.md).** This section keeps only what is
> 1Password-shaped: the items, their fields, and how to wire them.
>
> **Blocked on a credential right now?** It is yours to fix, not
> Alex's: `eval "$(bin/gh-auth-refresh --export)"`

Every repo lives under the **McRitchie-Studio** org, and `git`/`gh` authenticate as one of **two GitHub App** installations
rather than a personal token.

### The items

The two GitHub App items are split across the two vaults — `github.mcritchie-agent` in `studio-agents`, `github.mcritchie-admin` in `studio-agents-admin` — see the two-lane table above. A ship session therefore runs `source ~/.zprofile.admin` BEFORE `export GH_APP_ITEM=github.mcritchie-admin`; without the admin token the deployer read refuses, by design.

| Identity (1Password item) | Lane | Grants |
|---------------------------|------|--------|
| `github.mcritchie-agent` (**default**) | build / review | Contents write + **Pull requests write** + Checks read + Actions write + Workflows write + Administration write + Metadata/Statuses read |
| `github.mcritchie-admin` (`export GH_APP_ITEM=github.mcritchie-admin`) | ship | Contents write + Actions write + Checks read + Secrets write + Administration write + Metadata/Statuses read. **No `pull_requests` grant at all** — the deployer cannot open or merge PRs by design |

Grants above are the installations' live permission sets, read 2026-08-12 from
`GET /app/installations`. Re-read them there rather than trusting this table if a
`not accessible by integration` ever disagrees with it.

Each item carries fields `app-id` and `client-id`. **The private key is the
`.pem` FILE attachment on the item — the concealed `private key` field is NOT
the key.** `bin/gh-app-git-credential` finds it *by suffix*, so no key filename
is baked in to rot at the next rotation.

`GH_APP_ITEM` selects the item (default `github.mcritchie-agent`). That one
export governs **both** legs — the git credential helper and the token broker —
so the two can never disagree about which identity a session is.

### Wiring (global)

**Never point `~/.gitconfig` at a path inside a working tree.** `git checkout`
unlinks and recreates a file whose content differs between two commits, so for a
window the helper DOES NOT EXIST and any git operation needing credentials dies
with `gh-app-git-credential: No such file or directory`.

The production ship wires it. `bin/install-agent-docs`, the owned `sync_agent_docs`
step of `bin/release ship`, points the helper at the fixed-path tooling copy, a
`git archive` of the shipped tree behind an atomically swapped symlink that no
checkout touches ([`fast-lane.md`](fast-lane.md)). The line it runs:

```bash
git config --file ~/.gitconfig --replace-all credential."https://github.com".helper \
  "/Users/alex/projects/.agents/bin/gh-app-git-credential" '/gh-app-git-credential$'
```

It is a `--replace-all` carrying a value-pattern because
`[credential "https://github.com"]` holds TWO values here, an empty reset and
then the helper: a plain `git config … helper "<path>"` fails with *cannot
overwrite multiple values with a single value*, while a bare `--replace-all`
collapses both and lets the generic `[credential] helper = osxkeychain` answer
github.com. The pattern rewrites only this helper's own line, so the reset
survives and a re-run converges on one value; on a config with no reset the
installer adds the reset ahead of the helper. Until the first ship installs the
tooling, the installer keeps any helper line already there (a
`~/.mcritchie/git-credential` snapshot among them) and names the hub primary's
copy only when the config has no helper line at all.

`bin/install-git-credential-helper` is the by-hand alternative from before the
fixed path: it snapshots the helper's closure into
`~/.mcritchie/git-credential/versions/<digest>/` and prints the wiring line
(it never edits `~/.gitconfig`). The next ship repoints a line wired that way to
the fixed path, so prefer the ship's wiring. Mechanics: `bin/install-agent-docs`
(`install_git_credential_helper`) and `bin/lib/credential_helper_install.rb`.

Confirm access with a **real** read/write — not the repo permissions API, which
reflects the *account's* access, not the *token's* grant (this once masked a
read-only token): `gh pr list` for read, a throwaway branch `git push` for write.

**Never print a token.** Report a SHA-256 prefix instead. The full hygiene rules,
the dotted-JWT redaction pattern, and the revoke-and-re-mint procedure are in
[`source-control.md`](source-control.md).

## Fresh Machine

On a wiped machine:

1. Clone `mcritchie-studio`.
2. Run `bin/ecosystem-build` until it stops at the 1Password token step.
3. Copy the service account token to the clipboard.
4. Run `bin/setup-1pass-token`.
5. Re-run `bin/ecosystem-build`.

The full recovery path lives in [`../system/house-burn-down.md`](../system/house-burn-down.md).
