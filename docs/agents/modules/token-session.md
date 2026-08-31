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

A GitHub App gives you a **private key**, which never changes. The key signs a
short **JWT**, and the JWT buys an **installation token** that lives about an
hour. That installation token *is* the session. Every agent shares one, from a
file on disk, so the key is used at most once an hour per identity — not once
per `git push`.

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
| **Token rejected (401)** | retire that token, next call mints once | automatic |
| **1Password unreachable / quota spent** | nothing can mint — see below | **you** |
| **Deployer token needed, admin token absent** | cannot mint — escalate | **Mr. McRitchie** |

The 401 rung is worth understanding, because nothing else can notice it. A
credential helper never sees the 401 — git does. Git then calls the helper a
second time with `erase`, handing back the password that failed.
`bin/gh-app-git-credential` turns that into `bin/gh-token --reject "$token"`,
which drops **only the slot holding that exact token**. A sibling agent that has
already minted a replacement keeps it. Because the rejected value is then gone
from the cache, a second rejection of the same token matches nothing — that is
where "exactly once" comes from, with no counter to get wrong.

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
bin/gh-token --force >/dev/null && echo "minted"
```

## Symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| `Bad credentials`, 401 on `gh` | session aged out | step 1 |
| `could not read Username for 'https://github.com'` | the git credential helper could not mint | step 2, then step 1 |
| `"agents" isn't a vault` | **the hub primary is stale** | fast-forward `main`; the fix shipped as `bin/lib/op_vaults.rb` |
| `Too many requests` from `op` | account-wide daily quota | step 2 — read the `[ERROR]` line, not the summary |
| `gh` acts as a person, not a bot | an EMPTY token fell back to the keyring | never hand `gh` an empty `GH_TOKEN`; see the trap below |
| `REFUSING to merge <slug>` from `pr-review` | the merge-path identity assertion refused | read the line — it names which of the three causes; see the trap below |
| deployer mint fails in a build shell | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` absent **by design** | escalate |

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

## The one honest escalation

The **deployer** lane needs `OP_ADMIN_SERVICE_ACCOUNT_TOKEN`, which agent shells
do not carry — that absence is the isolation working, not a fault. A production
deploy therefore needs Mr. McRitchie to supply it. Everything on the `agent`
lane is yours to fix.

---

## Background — not needed to execute

Why the shared cache exists: the credential helper used to re-derive a session
from the private key on **every** git operation — three 1Password reads per
push, per fetch, per repo, per agent. A day of ordinary work spent the account's
1000-read daily quota and stopped every lane for eighteen hours, with eight
reviewed tasks unable to ship. Reading the shared session first makes a warm git
operation cost zero reads and a cold one two, at most once an hour per identity.

Deeper reference: `mcritchie-studio/docs/agents/modules/source-control.md`
(architecture, the three credential stores and how they rank) and
`mcritchie-studio/docs/agents/modules/credentials.md` (1Password conventions).
