# `token-session` — GitHub token sessions, self-healing

**Invocation:** `token-session` · **Owner:** Shared · **Read this file, then run it.**

Run this when a lane cannot reach GitHub: `Bad credentials`, a 401 or 403, a
`gh auth login` prompt, `could not read Username for 'https://github.com'`, or a
push that is refused on auth.

It is **self-service**. Fixing it is yours, in one command, and then you keep
going. Do not hand it to Mr. McRitchie — with one honest exception, named at the
bottom.

---

## The idea, in four lines

A GitHub App gives you a **private key**, which changes only when someone
rotates it. The key signs a short **JWT**, and the JWT buys an **installation
token** that lives about an hour. That installation token *is* the session.
Agents on the `agent` lane share one from a file on disk, so a warm `git push`
costs **zero** 1Password reads.

**How often the key is actually read** — there is no lock, so this is a floor,
not a ceiling. `agent` is cached, so N concurrent agents that all miss the cache
mint N tokens. `deployer` is never cached (`CACHEABLE_IDENTITIES = %w[agent]`),
so it mints on **every** call, by design.

## The two identities

| | `agent` | `deployer` |
|---|---|---|
| 1Password item | `github.mcritchie-agent` | `github.mcritchie-deployer` |
| Vault | `studio-agents` | `studio-agents-admin` |
| Token env | `OP_SERVICE_ACCOUNT_TOKEN` | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` |
| May | build, review, open + merge PRs | push `main`, deploy, read secrets |
| May **not** | push `main` | touch pull requests at all |
| Cached on disk? | **yes**, shared between agents | **never** |
| Default? | yes | only when a ship lane asks |

The lane → vault → token map has exactly one source: `bin/lib/op_vaults.rb`.
Read it rather than hardcoding a vault name.

**The deployer is deliberately uncacheable.** `bin/gh-token` refuses to write it
to disk, so a build lane cannot lift a ship credential off the filesystem. Ship
lanes are rare, so the cost is one extra mint. Do not "fix" this.

## The lifecycle — what happens, and who does it

| State | What happens | Who |
|---|---|---|
| **No token yet** (fresh boot, new machine) | mint one from the key, cache it | automatic |
| **Token present and fresh** | serve it — **zero** 1Password reads | automatic |
| **Token older than 50 min** | mint a replacement, cache it | automatic |
| **Token rejected (401) on a `git` operation** | retire that token, next call mints once | automatic |
| **Token rejected (401) on `gh` or an API call** | nothing retires it — it is served until it ages out | **you** — step 1 |
| **1Password unreachable / quota spent** | `op` cannot serve the key, so `bin/gh-token` cannot mint — but you can, from the recorded app id plus a local `.pem` | **you** — *When 1Password itself is down* |
| **Deployer token needed, admin token absent, machine provisioned** | `source ~/.zprofile.admin` in this shell, then retry | **you** |
| **Deployer token needed, and this machine has no `~/.zprofile.admin`** | install it once — `bin/setup-1pass-token --admin` | **Mr. McRitchie** |

The 401 rungs are worth understanding, and **only the git one self-heals**. A
credential helper never sees the 401 — git does. Git then calls the helper a
second time with `erase`, handing back the password that failed.
`bin/gh-app-git-credential` turns that into `bin/gh-token --reject "$token"`,
which drops **only the slot holding that exact token**. A sibling agent that has
already minted a replacement keeps it. Because the rejected value is then gone
from the cache, a second rejection of the same token matches nothing — that is
where "exactly once" comes from, with no counter to get wrong.

**A 401 from `gh api`, `gh pr`, or `bin/lib/ci_status.rb` never reaches the
helper**, because those never call it — so nothing is retired and the stale
token is served until it ages out. That is the case most readers arrive with,
since the trigger list at the top of this file leads with `gh` symptoms. Fix it
with step 1, which replaces the value in **your** shell.

## Do this

**1. Refresh this shell's credential.** This is the whole fix, most of the time.

```bash
cd /Users/alex/projects/mcritchie-studio
eval "$(bin/gh-auth-refresh --export)"
```

**2. If that fails, ask the broker why before waiting on it.**

```bash
op service-account ratelimit
```

It reports remaining and reset **directly**. On 2026-08-29 three separate retry
loops backed off politely for hours against an account whose daily quota was
already at 1000/1000 — an indefinite wait that one command turns into a
decision. A retry loop against a quota-limited broker **must** query the quota
before it sleeps.

⚠️ **`op service-account ratelimit` ITSELF COSTS A READ.** Poll it in a loop and
you are spending the quota you are measuring. Measured 2026-08-31: every read
observed during a 25-minute "steady state" window was the monitoring command.

**2a. Then ask WHAT SPENT IT — that part is a query now, not an investigation.**

```bash
bin/op-reads                 # by calling command, last 24h
bin/op-reads --since 3h      # a window: 45m, 3h, 7d, or an ISO8601 stamp
bin/op-reads --by action     # caller (default) | action | context | hour
bin/op-reads --tail 40       # the raw rows
```

Every `op` invocation the `bin/` stack makes is recorded to
`<projects>/.agents/op-reads.log` — calling command, action, outcome,
timestamp — by `bin/lib/op_meter.rb` (Ruby callers) and `bin/lib/op-meter.sh`
(shell callers). Reading that log costs nothing.

**Why this exists.** On 2026-08-31 the account showed 247 read_writes consumed in
three hours and nothing recorded which command spent them. Reconstruction by
measurement came up empty — `bin/task`: 0 reads, authenticated git ops: 0,
steady state: 0 — because the spend was **bursty**, concentrated across twelve
review subagents plus their merges and ships, roughly 20 reads per agent. And it
was the *second* time: `bin/gh-app-git-credential` already carried a comment
saying three reads per push/fetch/repo was "the reason a day of ordinary work
spent the account's quota". Found once, fixed once, un-findable again because
nothing logged it.

**Attributing a fan-out.** Export `MCR_OP_METER_CONTEXT` before spawning a batch
and `--by context` separates that batch's spend from everything else:

```bash
MCR_OP_METER_CONTEXT=review-sweep-2026-08-31 bin/pr-review
bin/op-reads --by context
```

There is **no alarm and no budget threshold**, deliberately. Once the spend is
attributable it is findable, and an alarm on a solved problem is noise.

**3. Inspect the cache without printing a secret.**

```bash
bin/gh-token --status
```

**4. Force a fresh mint** when you suspect the cached session, not the key:

```bash
eval "$(bin/gh-auth-refresh --force --export)"
```

Then **re-run step 1's check** — the command above has already replaced this
shell's `GH_TOKEN`, so `gh` should now answer.

Use `bin/gh-auth-refresh --force`, **not** `bin/gh-token --force`. `bin/gh-token`
mints into the shared cache and writes the token to *stdout*; discarding that
output leaves your `GH_TOKEN` exactly as broken as it was, so `gh` keeps failing
and the reader loops. `--force` bypasses the broker cache
(`bin/gh-auth-refresh:41`) and `--export` is the half that repairs **this
shell**.

## When 1Password itself is down — mint by hand

Steps 1-4 all end at `op`. When the broker is unreachable or the daily quota is
spent (step 2 tells you which), **you can still mint** — `bin/gh-app-mint-token`
takes its two halves from the environment and never touches 1Password:

| Half | Where it is when 1Password is down |
|---|---|
| `GH_APP_ID` — the numeric app id | `credential-inventory.md` → **GitHub App IDs**: agent **`4431410`**, deployer **`4431542`**. Also at `~/.config/mcritchie/app-ids.json` on Mr. McRitchie's Mac, but nothing creates that file — on a rebuilt machine, read the doc. |
| `GH_APP_PEM` — the private key | the `.pem` as last downloaded: `~/Downloads/mcritchie-{agent,deployer}.*.private-key.pem`. **Never** in the repo. |

```bash
cd /Users/alex/projects/mcritchie-studio
GH_TOKEN="$(GH_APP_ID=4431410 \
  GH_APP_PEM="$(cat ~/Downloads/mcritchie-agent.*.private-key.pem)" \
  bin/gh-app-mint-token)"
if [ -z "$GH_TOKEN" ]; then
  echo "mint FAILED — do not export an empty token"
else
  export GH_TOKEN
  gh api /installation/repositories --jq '.total_count'   # answers => the token works
fi
```

Executed 2026-08-30 during the quota outage that prompted this section: it
minted a working installation token with **zero** 1Password reads and the proof
call answered `10`. The empty-token guard is not decoration — see
*An empty token is not an absent one* below.

Two notes. **Do not `echo` the token**; capture it, use it, let it age out.
And for the **ship** lane swap in `4431542` and the deployer `.pem` — that pair
reaches its `McRitchie-Studio` installation, verified the same day.

**Why the app id is in the repo at all.** Before 2026-08-30 it lived only in
1Password, so this recipe — the documented fallback for "1Password is down" —
required 1Password. That circle cost a night's pushes. An app id is an identity
claim, not a credential: it is the JWT's `iss`, and GitHub checks the signature
against the app's **public** key, so the id alone earns a `401`. The reasoning
and the tests behind that classification are in `credential-inventory.md`.

## Symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| `Bad credentials`, 401 on `gh` | session aged out | step 1 |
| `could not read Username for 'https://github.com'` | the git credential helper could not mint | step 2, then step 1 |
| `"agents" isn't a vault` | **the hub primary is stale** | fast-forward `main`; the fix shipped as `bin/lib/op_vaults.rb` |
| `Too many requests` from `op` | account-wide daily quota | step 2 — read the `[ERROR]` line, not the summary; if the quota really is spent, mint by hand rather than wait |
| Quota spent and nobody knows by what | nothing recorded WHICH command read | step 2a — `bin/op-reads` (and `--by context` for a fan-out). Do NOT re-derive it by measurement; that was tried on 2026-08-31 and came up empty |
| `gh` acts as a person, not a bot | an EMPTY token fell back to the keyring | never hand `gh` an empty `GH_TOKEN`; see the trap below |
| `REFUSING to merge <slug>` from `pr-review` | the merge-path identity assertion refused | read the line — it names which of the three causes; see the trap below |
| deployer mint fails, and you hold the ship lane | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` is not in **this shell** | `source ~/.zprofile.admin`, then `export GH_APP_ITEM=github.mcritchie-deployer` **before** minting |
| deployer mint fails in an ordinary build shell | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` absent **by design** | that refusal is the isolation working — stop there |

## Two traps

**An empty token is not an absent one.** `GH_TOKEN="$(bin/gh-token)"` sets
`GH_TOKEN` to the empty string when the mint fails, and `gh` treats empty as
"not set" — so it silently falls back to the keyring, where a **personal**
account may be signed in. On 2026-08-29 two merges landed under Mr. McRitchie's
own account this way, with every agent having been told not to use it. Check the
value before exporting it, or let the command fail loudly.

**A merge no longer takes your word for it.** The instruction above already
existed on 2026-08-29 and was already followed — every agent had been told not
to use the personal credential, and none did; `gh` substituted it for them. So
the defence is mechanical, and it sits at the merge itself: `bin/pr-review`
asks `gh api user` **before** any write on the merge path and refuses unless the
answer is a GitHub App installation (`bin/lib/acting_identity.rb`). An App gets
403 "Resource not accessible by integration"; a person gets 200 with a login.
It **fails closed** — an identity it cannot determine is refused like a bad
one — and a refusal costs only a re-review, because the task stays `submitted`
and unstamped. An empty `GH_TOKEN` is caught from the environment without an API
call at all, and earns one mint-and-retry before the refusal stands.

Note the boundary: this guards the **feat → `accepted`** merge. The
`accepted → release` batch merge in `bin/release.rb` is not yet wired to it.

**Never run `gh auth login` to fix this.** `gh` refuses to store a credential
while `GH_TOKEN` is set, and `GH_TOKEN` outranks the keyring it would write to.
It is also the terminal chore the operating model forbids.

## The deployer lane — self-service on a provisioned machine

The **deployer** lane needs `OP_ADMIN_SERVICE_ACCOUNT_TOKEN`, which agent shells
do not carry. That absence is the isolation working, not a fault — and on a
machine that has been provisioned it is **still yours to fix**, because the
token is already on disk. It is simply not loaded into this shell:

```bash
source ~/.zprofile.admin
export GH_APP_ITEM=github.mcritchie-deployer   # BEFORE the push — see below
```

**Those two lines are the whole fix — there is no third command.** The deployer
is never cached (`bin/gh-token`'s `CACHEABLE_IDENTITIES`), so the next git
operation mints a fresh deployer token through the credential helper on its own.
There is no stale token to refresh by hand.

**Do NOT run `bin/gh-auth-refresh --identity deployer --export` here.** Bare, it
`puts` a live installation token to your terminal — into scrollback and any agent
transcript — and it still cannot alter the parent shell, so whatever you run next
fails identically. It is also the wrong lane: the deployer App has **no
`pull_requests` grant**, while `bin/release` calls `gh pr view`/`create`/`merge`,
so installing that token into `gh` makes a later failure *more* likely, not less.

**Export `GH_APP_ITEM` before you push, not after.** The credential helper reads
it at mint time, so setting it afterwards hands you the **agent** token instead —
a wrong-identity *success*, which is harder to notice than an outright refusal.

`bin/gh-token` tells you which case you are in: on a provisioned machine its
refusal names `source ~/.zprofile.admin`; only on a machine with no such file
does it name the install.

### The one honest escalation

**A 1Password outage is not it.** Whatever `op` is doing, the hand-mint above
needs neither the broker nor Mr. McRitchie, as long as the `.pem` is on this
machine. Reach for it before you decide the night is over.

A machine that has **never been given** an admin token — no `~/.zprofile.admin`
on disk at all — genuinely needs Mr. McRitchie, once, to run
`bin/setup-1pass-token --admin`. That is the only credential step on either lane
that is his. Everything else here, both lanes included, is yours.

Do not read a deployer refusal as that case without checking. On 2026-08-30 an
agent did exactly that and put a repeated hand-mint chore on Mr. McRitchie while
a production deploy waited; the token had been at `~/.zprofile.admin` since
2026-08-28, and sourcing it worked on the first try.

---

## Background — not needed to execute

Why the shared cache exists: the credential helper used to re-derive a session
from the private key on **every** git operation — three 1Password reads per
push, per fetch, per repo, per agent. A day of ordinary work spent the account's
1000-read daily quota and stopped every lane for eighteen hours, with eight
reviewed tasks unable to ship. Reading the shared session first makes a warm git
operation cost zero reads and a cold one two. There is no lock and no global
counter, so "one mint an hour" is the shape of the win, not a guarantee — see
*How often the key is actually read* above.

Deeper reference: `mcritchie-studio/docs/agents/modules/source-control.md`
(architecture, the three credential stores and how they rank) and
`mcritchie-studio/docs/agents/modules/credentials.md` (1Password conventions).
