# Credential Access: one way into 1Password
<!-- registry: read order, rotation, names-never-values, the vault permission map -->

Every agent, script and app process on this Mac that needs a credential follows
this procedure. It is the standing answer to one question: **where does this
credential come from right now?** It stands alone; the background lives in
[`credentials.md`](credentials.md) (the contract, lanes, Heroku tokens),
[`secret-cache.md`](secret-cache.md) (the expiring-credential cache) and
[`credential-inventory.md`](credential-inventory.md) (item names). This page
does not repeat them; it orders them.

**Why it exists.** 1Password gives the whole account **1,000 read_writes per
rolling 24 hours**, shared by every service account and every agent. That is the
design budget: Alex McRitchie ruled on 2026-10-31 that the plan stays at 1,000 a
day ("We should be able to manage with 1000 today with the right credentials in
the right places"), so a caller that needs more is the defect, not the plan. On
2026-10-31 that quota ran out and every agent stalled for about five hours. Two
causes, both measured: a watcher re-read `op` once a minute for hours while
1Password was down, and a list of callers ran `op` directly, so `bin/op-reads`
could not attribute the spend. Alex McRitchie asked for deterministic code that
works off the env files, and one standard every agent knows.

## 1. The read order

Take the first rung that answers. Never skip down a rung to "be sure".

| Rung | Source | Costs a read? | How |
|------|--------|---------------|-----|
| 1 | The process environment, or the repo's env file | No | `ENV["NAME"]`; `.env` / `.env.development` (table below) |
| 2 | The secret cache, `/Users/alex/projects/.secret-cache/` | No | `bin/secret get <name>`, `bin/gh-token` |
| 3 | 1Password, through the one metered wrapper | **Yes** | Ruby: `OpMeter.popen`. Shell: `op_metered` (`bin/lib/op-meter.sh`). By hand: `bin/secret <vault> <item> [field]` |

- **Rung 3 is the only way to run `op`.** A raw `op read`, `op item get`,
  `IO.popen(["op", …])` or `Open3` call is invisible to `bin/op-reads`.
  `test/lib/op_call_guard_test.rb` fails on a new one in `bin/`, `app/` or `lib/`;
  the few allowed exceptions are listed there, each with its reason.
- **A process reads a key once.** Memoize it (`AgentApi#op_secret`), or export it
  for the children (`HerokuToken.export_once!`). A retry bills too.
- **GitHub tokens come only from `bin/gh-token`**, which serves the shared cache and
  reads 1Password only on a miss or expiry. A watcher that must never spend the
  quota asks `bin/gh-token --cached-only` (exit 3 on a miss, never reads `op`).
- **When 1Password is hung or rate-limited, nobody retries it.** `bin/gh-token`
  records that account-wide failure in the cache manifest and every process skips
  `op` until the window ends (1 minute, doubling to 15). `bin/secret status` shows
  the window. After fixing 1Password, skip it for one call with
  `MCR_OP_NO_BACKOFF=1 bin/gh-token`. A failure one shell owns (its token not
  sourced) does not back off the others.

### Stable keys come from env files

A key that does not expire and is not admin is read from an env file at run time,
not from 1Password. The env file is written once from 1Password by the script
named, and read for free after that. Production dynos read Heroku config and are
untouched by any of this.

| Keys | Env file | Read by | Written from 1Password by |
|------|----------|---------|---------------------------|
| `AGENT_API_SECRET` | `mcritchie-studio/.env` | `bin/lib/agent_api.rb`, `bin/lib/task_board.rb` (env, then `.env`, then one metered read) | `bin/conductor-host-setup` prints the one-line fix (item `Agent API Secret`) |
| `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` (the dev pair) | `<app>/.env.development` | each app's storage config | `bin/ecosystem-build`, only when the file is missing or empty (item `r2.<app>`) |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (the dev OAuth client) | each app's `.env` | the Rails apps locally | `bin/dev-google-client` (item `google.studio.local`) |
| `GMAIL_OAUTH_CREDENTIAL` | the app's `.env` | `Gmail::Credentials` (env first; else one metered read) | by hand from item `gmail.studio.agents` |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | the app's `.env` | `Workspace::Credentials` (env first; else one metered read) | by hand from item `google.industries.agents` |
| `X_API_KEY`, `X_API_SECRET`, `X_ACCESS_TOKEN`, `X_ACCESS_TOKEN_SECRET` | the shell or `.env` | `bin/x-post` (env first; else one metered `item get`) | by hand from item `agent.turf.x` |

Expiring or rotating credentials (GitHub App tokens, the harness key) are NOT
env-file keys: they live in the secret cache, rung 2. Heroku tokens are read at
use, never kept in a profile ([`credentials.md`](credentials.md), Heroku tokens
resolve at use time).

## 2. Rotation flips one place

The 1Password item is the one source. Rotating a key is:

1. Change the item (the provider first, then the item;
   [`credential-rotation`](../agents/steffon/sops/credential-rotation.md)).
2. Drop every copy derived from it: `bin/secret forget --source <item>` for the
   cache; delete the key's line from each env file in the table above and re-run
   the script that writes it; Heroku config through the rotation SOP.
3. Nothing else changes. No doc, memory note, profile or script holds the value,
   so none needs editing.

## 3. Memory, docs and chat hold names, never values

An agent may write down **where** a credential is: the vault, the item, the field,
the `bin/secret` name, the env-file key. It never writes **what** it is: no value,
no prefix longer than a digest's first few characters, no item contents, no
screenshot of a field.

- **A memory note goes stale after a rotation.** Update the reference (a renamed
  item, a moved vault, a new field name). Never paste the new value to "fix" it.
- **A memory note or doc that holds a value** is an exposure, not a note: delete
  the value, keep the reference, and run
  [`credential-issues`](credential-issues.md) (the value is treated as leaked).
- Agent-side filing: the agent makes the item itself with the secret field empty,
  and Alex McRitchie pastes only the secret ([`credential-filing`](../agents/steffon/sops/credential-filing.md)).

## 4. The vault permission map

Two service-account tokens exist today, both on this one Mac. `bin/lib/op_vaults.rb`
holds the same map as code (`OpVaults::LANES`, `OpVaults::VAULTS`), and
`test/lib/credential_access_vault_map_test.rb` pins this table to it, both ways.
Change them together.

| Lane | Token | Loaded from | Soul class |
|------|-------|-------------|------------|
| `agent` | `OP_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile`, every shell | every soul |
| `deployer` | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile.admin`, opt-in | Admin class only |

<!-- vault-map:start -->
| Vault | Holds | Read by lane | Future machine |
|-------|-------|--------------|----------------|
| `studio-agents` | Agent credentials wielded by judgment: the board secret, the agent GitHub App, Heroku agents token, app API keys | `agent` | agent |
| `industries-agents` | Industries-brand agent credentials (the Workspace service account) | `agent` | agent (to confirm) |
| `family-agents` | Family-brand agent credentials | `agent` | agent (to confirm) |
| `Commercial Welding` | The Commercial Welding business | `agent` | agent (to confirm) |
| `studio-applications` | Credentials deployed software consumes: durable copies of Heroku config and Actions secrets | `agent`, `deployer` | admin (to confirm) |
| `studio-agents-admin` | Ship and provisioning credentials: the admin GitHub App, Heroku admin token, governance keys | `deployer` | admin |
<!-- vault-map:end -->

- **Admin class** is `AgentSession::ADMIN_SOULS` (Steffon, Mason), and a session
  holding the `deployer` lane for a production act. **Worker class** is everyone
  else. Alex (the agent) and Mack are Worker class by name: no admin vault, no
  admin login request, ever.
- **An admin lane is MEANT to hold admin credentials.** On an admin lane, an
  absent admin token is a setup gap (`source ~/.zprofile.admin`), not a closed
  door ([`credentials.md`](credentials.md), An admin lane is MEANT to hold admin
  credentials). The isolation is that ordinary shells never load it.
- **Personal vaults are off-limits.** No service account can see Alex McRitchie's
  private or family vaults, and no agent reaches them another way: the 1Password
  browser extension in the admin Chrome profile sees all of his accounts, and an
  agent never opens, reads, searches or fills from it.
- **Future machine.** Today every row runs on one Mac. Alex McRitchie approved the
  split on 2026-10-31: the **agent machine** carries the `agent` lane and
  `studio-agents`; the **deploy/admin machine** carries the `deployer` lane and
  `studio-agents-admin`; **personal vaults go on no agent machine at all.** Nothing
  routes on the column yet; it is the organization, in place first.
- **"(to confirm)" is a placement for Alex McRitchie to confirm.** The business and
  client vaults are placed by the token that reads them today (the agent token).
  `studio-applications` is read by both tokens and written by the deployer, so it
  is placed with the deployer pending his word. On his answer, change
  `OpVaults::VAULTS` and this row together and drop the flag.

### Taking the vault inventory

`op vault list` costs a read and prints names only. Run it **at most once** per
re-measure, on the lane you are in, and never read an item's value to build or
check the map. Record what it returned in `OpVaults::VAULTS` and this table in
the same change. Last measured 2026-10-31 on the agent token (the five `agent`
rows above); the `deployer` rows are from
[`credential-inventory.md`](credential-inventory.md).

## 5. Diagnosing a spend

1. `bin/op-reads --since 24h` (free): reads by calling command. Add `--by hour`,
   `--by context`, or `--tail 40` for the raw rows. A row with context `-` came
   from a process with no Claude session (launchd, git's credential helper).
2. `OP_CACHE=false op service-account ratelimit` (costs one read): the token and
   account counters. Run it once before a batch of 1Password work, not in a loop.
3. A burst of `timeout` rows is a hung 1Password, not a spend: quit and reopen
   the app ([`secret-cache.md`](secret-cache.md), when 1Password fails).

**The 2026-10-30/31 caller, for the record.** The dispatcher's harness probe
(`bin/lib/agent_harness_probe.rb`, run every 60 seconds by the
`studio.mcritchie.agent-dispatcher` launchd job) asked `bin/gh-token` for a token
on every beat. With the cache expired and 1Password hung, then out of quota, each
beat went back to `op` and was killed at its 20-second bound: 1,075 sessionless
failed `gh-token` attempts in the two windows (2026-10-30 05:00 to 14:00 and
2026-10-31 04:00 to 16:00 UTC), 72% of every `gh-token` row from the first
window's start to the second's end. The probe now asks `--cached-only` when `op whoami` fails, and the
account-wide backoff covers the rate-limited case.
