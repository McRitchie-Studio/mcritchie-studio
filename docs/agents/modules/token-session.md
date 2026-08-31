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
| Vault | `agents-studio` | `agents-admin` |
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
| **1Password unreachable / quota spent** | nothing can mint — see below | **you** |
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

## Symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| `Bad credentials`, 401 on `gh` | session aged out | step 1 |
| `could not read Username for 'https://github.com'` | the git credential helper could not mint | step 2, then step 1 |
| `"agents" isn't a vault` | **the hub primary is stale** | fast-forward `main`; the fix shipped as `bin/lib/op_vaults.rb` |
| `Too many requests` from `op` | account-wide daily quota | step 2 — read the `[ERROR]` line, not the summary |
| `gh` acts as a person, not a bot | an EMPTY token fell back to the keyring | never hand `gh` an empty `GH_TOKEN`; see the trap below |
| deployer mint fails, and you hold the ship lane | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` is not in **this shell** | `source ~/.zprofile.admin`, then `export GH_APP_ITEM=github.mcritchie-deployer` **before** minting |
| deployer mint fails in an ordinary build shell | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` absent **by design** | that refusal is the isolation working — stop there |

## Two traps

**An empty token is not an absent one.** `GH_TOKEN="$(bin/gh-token)"` sets
`GH_TOKEN` to the empty string when the mint fails, and `gh` treats empty as
"not set" — so it silently falls back to the keyring, where a **personal**
account may be signed in. On 2026-08-29 two merges landed under Mr. McRitchie's
own account this way, with every agent having been told not to use it. Check the
value before exporting it, or let the command fail loudly.

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
