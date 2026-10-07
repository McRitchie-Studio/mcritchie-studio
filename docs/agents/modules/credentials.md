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
`STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`. The 2026-10-06 sweep found the
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

Kept by design: `RAILS_MASTER_KEY` and `AGENT_API_SECRET`.

⚠ **`fix` removing `SOLANA_ADMIN_KEY` stops turf's local devnet admin signing**:
the devnet `VaultState` seats only `8K81…`, Alex and Mason, so local dev has no
devnet-only signer until one is seated (turf-monster
`docs/qa-signing-key-rotation.md`, "What this ceremony does not fix").

## How a soul logs in to the board

The board API takes two bearers (design:
[`../system/agent-sessions-design.md`](../system/agent-sessions-design.md)).

- **An agent session.** `bin/task begin` logs the desk's soul in to the task it
  claimed (`POST /api/v1/agent_sessions`, presented with the shared token) and keeps
  the session token in `agent-session.json` inside the desk's git directory,
  owner-only, where no commit can reach it. A studio session is scoped to that task,
  lives while the task is `building` or `submitted`, and expires after 24 hours. Its
  soul is the actor on every board write it makes; an `actor` or `by` param is
  ignored. It may write only its own task, and a release endpoint answers 403.
- **The shared token** from `AGENT_API_SECRET` (`POST /api/v1/auth`). It still works
  everywhere for one release, with each use logged as `[agent-auth] legacy`, so Turf
  Monster's two endpoints and installed hooks keep running.

Admin sessions (Steffon, Xan) are unscoped within the admin tier and expire after
8 hours; the operator grant that issues them is not built yet. Every refusal answers
401 (the session ended: revoked, expired, or the task moved on) or 403 (tier or
scope) with the reason. `GET /api/v1/agent_sessions/current` says who a bearer is;
`DELETE` on the same path logs out.

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
