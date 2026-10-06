# `token-session` — GitHub token sessions, self-healing

**Invocation:** `token-session` · **Owner:** Shared · **Read this file, then run it.**

Run this when a lane cannot reach GitHub: `Bad credentials`, a 401 or 403, a
`gh auth login` prompt, `could not read Username for 'https://github.com'`, or a
push that is refused on auth.

It is **self-service**. Fixing it is yours, in one command, and then you keep
going. Do not hand it to Alex — with one honest exception, named at the
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
| 1Password item | `github.mcritchie-agent` | `github.mcritchie-admin` |
| Vault | `studio-agents` | `studio-agents-admin` |
| Token env | `OP_SERVICE_ACCOUNT_TOKEN` | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` |
| May | build, review, open + merge PRs | push `main`, deploy, read secrets |
| May **not** | push `main` | touch pull requests at all |
| Cached on disk? | **yes**, shared between agents | **never** |
| Default? | yes | only when a ship lane asks |

The `deployer` lane's App is `mcritchie-admin` since 2026-09-26 (same app id and
key). Its old item name is retired: `GH_APP_ITEM` is matched by exact name, and any
other value is refused before a 1Password read.

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
| **Token present, but the one in YOUR shell is stale** | the session inherited a revoked `OP_SERVICE_ACCOUNT_TOKEN` while `~/.zprofile` already holds the live one; `op` then fails exactly as it would for a service account that no longer exists | **you** — step 1a |
| **1Password unreachable, quota spent, or the service account genuinely gone** | `op` cannot serve the key, so `bin/gh-token` cannot mint — but you can, from the recorded app id plus a local `.pem`. **Two legs, `gh` and `git`, and both are yours to arm** | **you** — **step 1a first**, then *When 1Password itself is down* |
| **Deployer token needed, admin token absent, machine provisioned** | `source ~/.zprofile.admin` in this shell, then retry | **you** |
| **Deployer token needed, and this machine has no `~/.zprofile.admin`** | install it once — `bin/setup-1pass-token --admin` | **Alex** |

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

**1a. If step 1 fails, reset a stale environment BEFORE you blame the broker.**
Two commands and a check, no 1Password read, and on 2026-09-27 it was the whole
fix for four agents who had already walked past it to the hand-mint at the bottom
of this file.

```bash
unset OP_SERVICE_ACCOUNT_TOKEN   # the AGENT lane; deployer: OP_ADMIN_SERVICE_ACCOUNT_TOKEN
source ~/.zprofile               # the AGENT lane; deployer: ~/.zprofile.admin
op whoami                        # `User Type: SERVICE_ACCOUNT` => recovered
```

The reset repaired `op`, not your `GH_TOKEN` — they are two separate values — so
finish by re-running step 1 in the same shell:

```bash
eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"
```

Once `gh` answers, **stop here.** Everything below step 1a is written for a broker
that genuinely cannot serve, which is not the case you are in.

**A service-account token lives in two places, and the stale one wins.** Your
shell inherited `OP_SERVICE_ACCOUNT_TOKEN` when the session was spawned;
`~/.zprofile` holds whatever the value is *now*. Rotate or revoke a token and the
profile is updated while every already-running session keeps presenting the dead
one — and because the variable is still *set*, `op` reports a **broken**
credential rather than a missing one. That is why this arrives looking like a
dead account instead of a stale shell.

⚠ **`(403) Forbidden (Service Account Deleted)` does NOT mean the account is
deleted.** It means the token you presented names a service account that no
longer exists, which is exactly what a stale environment variable produces.
Measured 2026-09-27: `op whoami` answered that 403 all afternoon; after the two
commands above it answered `User Type: SERVICE_ACCOUNT`, `op vault list` returned
five vaults including `studio-agents`, `bin/gh-token` minted, and
`gh api /installation/repositories --jq '.total_count'` answered 18. Four agents
read that 403 as a dead account and reached for the bypass. The account was live
the whole time.

**Do not gate this on the profile's mtime.** The file's timestamp is not a
precondition for anything on this page: run the reset, then read
`ls -la ~/.zprofile*` afterwards if you want to know which profiles exist and when
each was written. A profile older than today can still hold the
good token, and that is now measured twice on the very cases the gate was
drawn from. On 2026-09-27 `~/.zprofile` was dated two days earlier and the reset
worked anyway; on 2026-09-28 a shell was answering the same 403 with the file
dated **three** days earlier, and the reset recovered it again. What goes stale is
the long-lived process the session was spawned from, not the file — no file clock
can see that, so a reader who treats the mtime as a condition concludes "the
environment is fine" and walks on to the `.pem` bypass at the bottom of this
document. That is the exact wrong turn this step exists to prevent. Run the reset
rather than predicting it; it is two commands and a check.

**This is the agent lane's twin of a remedy this file already gave the deployer
lane.** `source ~/.zprofile.admin` appears in the lifecycle table above, in the
symptom table below, and twice in *The deployer lane*; the agent lane had no
equivalent anywhere, and step 2 sent the reader straight to the broker. That
asymmetry is why four agents in one day skipped the two cheapest commands in this
document. **Add a remedy for one lane, add it for both.**

**2. If the reset did not recover it, ask the broker why before waiting on it.**

```bash
op service-account ratelimit
```

It reports remaining and reset **directly**, which turns an indefinite wait into
a decision. A `(403) Forbidden (Service Account Deleted)` here is not a quota
line at all, and almost never a dead account — go back to **step 1a**. A retry
loop against a quota-limited broker **must** query the quota before it sleeps.
⚠️ **The command ITSELF COSTS A READ**, so never poll it in a loop.

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

Do not re-derive the spend by measurement: it is bursty (a review fan-out spends
about 20 reads per agent), and only the log attributes it.

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
and the reader loops. `--force` bypasses the broker cache (it is
`bin/gh-auth-refresh`'s own flag, forwarded to the broker) and `--export` is the
half that repairs **this shell**.

## When 1Password itself is down — mint by hand, on BOTH legs

Steps 1-4 all end at `op`. **This is the last rung, not the first.** Run step 1a
before you come here: a 403 that reads like a dead account is usually a stale
token in your own shell, and on 2026-09-27 four agents reached this section with
a perfectly live service account. When the reset does not recover it and the
broker really cannot serve — unreachable, quota spent, or the account genuinely
gone — **you can still mint**: `bin/gh-app-mint-token` takes its two halves from
the environment and never touches 1Password:

| Half | Where it is when 1Password is down |
|---|---|
| `GH_APP_ID` — the numeric app id | [`credential-inventory.md`](credential-inventory.md) → **GitHub App IDs**: agent **`4431410`**, deployer **`4431542`**. Also at `~/.config/mcritchie/app-ids.json` on Alex's Mac, but nothing creates that file — on a rebuilt machine, read the doc. |
| `GH_APP_PEM` — the private key | the `.pem` as last downloaded: `~/Downloads/mcritchie-{agent,deployer}.*.private-key.pem`. **Never** in the repo. |

**This is a bypass, not a repair.** It works only on a machine that already has
the `.pem` on disk, so it does not generalise — not to a fresh Mac, not to CI,
not to an agent whose box never held the key. It also fixes nothing about the
broker: a quota-spent service account is still quota-spent afterwards.

**No open ticket sits behind this, and nothing here waits on Alex.**
`restore-agent-service-account` was filed on the premise that the agent service
account no longer existed. That premise measured false, and the task is `archived`
— read the board rather than taking this sentence's word for it:
`bin/task show restore-agent-service-account --json | jq -r .stage` answers
`archived`. Both of its acceptance criteria measure true. Measured 2026-09-28 from a shell
where `op whoami` was answering the 403, after step 1a and nothing else:
`bin/gh-auth-refresh --force --export` bypassed the shared cache and minted a
fresh token (a new `sha256:` prefix on stderr, so it was a real mint and not a
cache hit), and `gh api /installation/repositories --jq '.total_count'` answered
18. So when this recipe is what gets you moving, the follow-up is step 1a — not a
ticket, and not Alex.

### There are two legs, and they are armed separately

[`credential-inventory.md`](credential-inventory.md) records the agent App as
serving **two legs**. They reach a credential by different routes, and
`export GH_TOKEN=…` arms the **first one only**.

| Leg | Who needs it | How it gets a token | Symptom when that leg is unarmed |
|---|---|---|---|
| **`gh`** | `gh api`, `gh pr …`, `bin/lib/ci_status.rb`, every CI gate | reads the ambient `GH_TOKEN`. **`gh` never consults a git credential helper.** | `Bad credentials`, or a 401/403 out of `gh` |
| **`git`** | `git push` | the credential helper `bin/gh-app-git-credential`, which asks `bin/gh-token` for the shared session and then falls through to `op`. **`git` never reads `GH_TOKEN`.** | `fatal: could not read Username for 'https://github.com'` — except in the hub, where it is `remote: Invalid username or token` |

So an agent that exports `GH_TOKEN`, watches `gh` answer, and calls itself
unblocked can still die on the push. That is what ended a ship at step 3 of 8 on
2026-09-27, with `remote: Invalid username or token`.

**Arm the shell that actually pushes.** Exported values reach child processes, so
`bin/ship` inherits them — but a value set in a terminal you have since left, or
in a subshell that has already exited, reaches nothing. In the hub that failure
looks identical to an unarmed one, because the fallback below answers either way.

**Telling the two apart.** `gh` answers and the push fails ⇒ the **git** leg is
unarmed, so arm leg 2 below. *Neither* answers ⇒ you have not minted at all, so
start at leg 1.

**Why the hub's symptom differs, and why its green does not travel.** One claim,
and it is checkable: **`mcritchie-studio` is the only checkout on this machine
carrying a repo-local `gh` fallback.** The sweep behind it, so you never have to
take the number on trust:

```
cd /Users/alex/projects
for d in */; do r="${d%/}"; [ -e "$r/.git" ] || continue
  printf '%-24s %s\n' "$r" \
    "$(git -C "$r" config --local --get-all credential.https://github.com.helper)"
done
```

19 checkouts, one `gh` fallback (re-measured 2026-09-28). Quote its value as it
really reads — an **absolute** path, not a bare `gh`:

```
helper = !/opt/homebrew/bin/gh auth git-credential
```

`moms-app` answers with a repo-local line too, but it duplicates the App helper
the global config already names, so it is not a fallback. Every other checkout has
no local line at all: `bin/gh-app-git-credential` is then the only helper git can
reach, and a push with the shared session cold ends at `could not read Username`.

Git tries the hub's fallback *after* the App helper comes up empty, because a
local value appends to the global list rather than replacing it. Measured in the
hub, where `git config --get-all credential."https://github.com".helper` answers
three values in order — an empty reset, the App helper, then the `gh` one. That
helper hands over whatever `gh`'s keyring holds for its active account, and when
that token is stale GitHub answers `remote: Invalid username or token`.

The same fallback is why exporting `GH_TOKEN` alone *appears* to fix `git` **in
the hub**: it fixes it nowhere else, this paragraph is the only place the config
is documented, and every hub desk inherits it because worktrees share
`.git/config`. Nothing in this repo wrote that line, and nothing in it can.
The one git config this repo does write is the **global** App helper line,
which the production ship points at
`/Users/alex/projects/.agents/bin/gh-app-git-credential`
([`source-control.md`](source-control.md));
**`bin/install-git-credential-helper` writes no git config at all.** Its own
`--help` says so ("This command never edits ~/.gitconfig. It prints the one-line
change and its revert; you run them"), and
`bin/lib/credential_helper_install.rb#git_config_command` only *builds the
string* the CLI prints. The one-liner it prints is `--global`; the hub's line is
repo-local and was set by hand. Work around it; do not rely on it, and do not
remove it — that config is Alex's call.

### The recipe

```bash
cd /Users/alex/projects/mcritchie-studio

# Both legs read the same two halves. Export them once.
export GH_APP_ID=4431410
export GH_APP_PEM="$(cat ~/Downloads/mcritchie-agent.*.private-key.pem)"

# ── Leg 1: gh ─────────────────────────────────────────────────────────────────
GH_TOKEN="$(bin/gh-app-mint-token)"
if [ -z "$GH_TOKEN" ]; then
  echo "mint FAILED — do not export an empty token"
else
  export GH_TOKEN
  echo "GH_TOKEN armed, length ${#GH_TOKEN}"              # a LENGTH, never the value
  gh api /installation/repositories --jq '.total_count'   # a number => leg 1 works
fi

# ── Leg 2: git ────────────────────────────────────────────────────────────────
export GH_APP_TOKEN_CMD=/Users/alex/projects/mcritchie-studio/bin/gh-app-mint-token
git push --dry-run origin HEAD                           # read the answer below
```

Both legs mint with **zero** 1Password reads. **Do not `echo` the token**, keep
the empty-token guard (see *An empty token is not an absent one* below), and
print only a length or a masked prefix. ⚠ **Never presence-check a token with
`${GH_TOKEN:-unset}`** — that form *expands the secret* whenever the variable is
set, into your scrollback and the session transcript. Use `[ -n "$GH_TOKEN" ]` or
`${GH_TOKEN:+set}`.

Run it from the hub or from your own desk — both carry `bin/gh-app-mint-token` —
but give `GH_APP_TOKEN_CMD` an **absolute** path either way: the credential
helper runs with git's working directory, not yours, so a relative path resolves
nowhere and the override silently does nothing.

`GH_APP_TOKEN_CMD` is the hook for leg 2, and it has to be that one. The helper
folds it into `bin/gh-app-git-credential#GH_TOKEN_CMD`, runs that as its
**first** credential source (`bin/gh-app-git-credential#CACHED`) before any `op`
call, and accepts the result only when it is shaped `gh[su]_*` — so a command
that prints an error instead of a token is refused rather than pushed.

Two rhyming names that do **not** work here:

- `GH_APP_MINT_CMD` replaces the minter further down
  (`bin/gh-app-git-credential#TOKEN`), *after* the `op item get` and `op read`
  that fetch the PEM and the app id — so that path still dies at the broker.
- `bin/gh-token` is not an alternative to `bin/gh-app-mint-token`. It reads the
  app id and the PEM **only** through `op` (`bin/gh-token#mint`) and honours no
  `GH_APP_PEM`; it is the script that *passes* those two variables to the minter,
  not one that accepts them.

Two consequences of arming leg 2:

- **`bin/gh-token` leaves the path entirely**, so the shared session cache is
  neither read nor written and every git operation mints its own installation
  token. One extra API round trip per git operation, no 1Password reads, and — the
  point — a result that is yours rather than a sibling's.
- **Identity then comes from `GH_APP_ID`/`GH_APP_PEM`, not from `GH_APP_ITEM`.**
  `bin/gh-app-mint-token` reads neither `GH_APP_ITEM` nor the `--reject` argument
  the helper's `erase` branch passes it (`bin/gh-app-git-credential#REJECTED`), so
  a rejected credential costs one minted token nobody reads — wasteful, never
  fatal. For the **ship** lane, swap the app id to `4431542` and the PEM to the
  deployer `.pem`; exporting
  `GH_APP_ITEM` on its own would leave leg 2 on the agent identity, which is a
  wrong-identity *success* and harder to notice than a refusal.

The app id is an identity claim, not a credential, which is why it may live in
the repo: [`credential-inventory.md`](credential-inventory.md) has the reasoning.

### A check per leg — and how to read it

A recipe without a check is how the next agent discovers the gap at step 3 of 8.

**Leg 1** — `gh api /installation/repositories --jq '.total_count'`. Any number
is a pass; it answered **18** on 2026-09-27. `Bad credentials` is a fail.

**Leg 2** — `git push --dry-run origin HEAD`. Name `origin HEAD` explicitly: a
fresh desk branch has no upstream, and a bare `git push --dry-run` then fails on
upstream configuration **without ever contacting the remote**, so it cannot
verify anything. Judge the answer on *what GitHub talked about*, not on the exit
code:

| Answer | Verdict |
|---|---|
| `Everything up-to-date`, `! [rejected] … (non-fast-forward)`, `* [new branch] …` | **pass** — you were authenticated, and GitHub then discussed refs |
| `fatal: could not read Username for 'https://github.com'` | **fail** — no helper produced a credential at all |
| `remote: Invalid username or token`, `Authentication failed` | **fail** — a credential was produced and GitHub rejected it |
| `fatal: The current branch … has no upstream branch` | **inconclusive** — the remote was never reached. You dropped `origin HEAD` |

Two traps in that check:

- **`git ls-remote` and `git fetch` prove nothing.** The org's repos are readable
  unauthenticated — an unauthenticated `GET /repos/McRitchie-Studio/mcritchie-studio`
  answered `200` on 2026-09-27 — so they succeed with no credential whatsoever.
  Only a **push** exercises the git leg. `--dry-run` writes nothing: a pass reads
  `* [new branch] HEAD -> feat/<slug>` and no such branch exists afterwards
  (verified 2026-09-27 — `gh api …/branches/<branch>` answered `404`).
- **A green push *before* you arm proves nothing either.** The session cache is
  shared between agent processes, so a sibling's still-fresh token can carry your
  push and hide the gap until it ages out mid-run. Arm first, then check.

## Symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| `Bad credentials`, 401 on `gh` | session aged out | step 1 |
| `could not read Username for 'https://github.com'` | the git credential helper could not mint, and no other helper answered | step 1, then **step 1a**, then step 2 — and if `op` still cannot serve, *When 1Password itself is down* → **leg 2**. Exporting `GH_TOKEN` never reaches `git` |
| `gh` answers but `git push` still fails | **only the `gh` leg is armed.** They are two legs with two routes | **step 1a** first if you have not run it — a broken `op` starves the git leg while an exported `GH_TOKEN` keeps `gh` answering. Then *When 1Password itself is down* → **leg 2** (`GH_APP_TOKEN_CMD`), and re-check with `git push --dry-run` |
| `remote: Invalid username or token` on a push **in the hub** | the App helper came up empty and the hub's repo-local `!/opt/homebrew/bin/gh auth git-credential` fallback answered with a stale keyring token. No other checkout on this machine has that fallback, so they say `could not read Username` instead | **step 1a** first — an empty App helper is usually a stale `OP_SERVICE_ACCOUNT_TOKEN`, not a broker that cannot serve. Only then arm **leg 2**. Do not chase the local config; leave it alone |
| `op` answers `(403) Forbidden (Service Account Deleted)` | **almost never a deleted account.** The token in your shell is stale — it names a service account that no longer exists, while `~/.zprofile` already holds the live one. The variable is still *set*, so it reads as a broken credential rather than a missing one | **step 1a** — `unset OP_SERVICE_ACCOUNT_TOKEN`, `source ~/.zprofile`, `op whoami`. Only if it STILL 403s after that is the account genuinely gone, and only then the hand-mint |
| `"agents" isn't a vault` | **the hub primary is stale** | fast-forward `main`; the fix shipped as `bin/lib/op_vaults.rb` |
| `Too many requests` from `op` | account-wide daily quota | step 2 — read the `[ERROR]` line, not the summary; if the quota really is spent, mint by hand rather than wait |
| `op read` of the `.pem` attachment answers `(401) Unauthorized` while the item's fields read fine | a 1Password service-side fault on file attachments, not a revoked grant or the quota | mint by hand (*When 1Password itself is down*) and re-test later in a fresh session |
| Quota spent and nobody knows by what | nothing recorded WHICH command read | step 2a — `bin/op-reads` (and `--by context` for a fan-out). Do NOT re-derive it by measurement; that was tried on 2026-08-31 and came up empty |
| `gh` acts as a person, not a bot | an EMPTY token fell back to the keyring | never hand `gh` an empty `GH_TOKEN`; see the trap below |
| `ci:unreadable` on a task's `dor_review` gate row | the token expired **mid-gate** — CI was never read, and was never red | step 1, then re-run `bin/dor-check <slug> --gate-role review`. Do NOT chase a red CI; there is none |
| `ci:no_checks` or `ci:unverified` on that row | **NOT a token fault.** The PR reported no checks yet, or `gh` fell over on the network | nothing here helps — wait for CI, or re-read. Rotating a credential that was fine is the wasted move this row exists to prevent |
| `ci:no_pr` on that row | **NOT a token fault, and not a fault at all.** `devops.pr_url` is blank, so no PR was read; submit-side this is the ordinary state | open the PR, then re-run the gate. Before `/tasks/no-pr-records-as-fail` this row said `unverified`, which sent readers here to chase a credential that was never involved |
| `REFUSING to merge <slug>` from `pr-review` | the merge-path identity assertion refused | read the line — it names which of the three causes; see the trap below |
| deployer mint fails, and you hold the ship lane | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` is not in **this shell** | `source ~/.zprofile.admin`, then `export GH_APP_ITEM=github.mcritchie-admin` **before** minting |
| deployer mint fails in an ordinary build shell | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` absent **by design** | that refusal is the isolation working — stop there |

## Two traps

**An empty token is not an absent one.** `GH_TOKEN="$(bin/gh-token)"` sets
`GH_TOKEN` to the empty string when the mint fails, and `gh` treats empty as
"not set" — so it silently falls back to the keyring, where a **personal**
account may be signed in. On 2026-08-29 two merges landed under Alex's
own account this way, with every agent having been told not to use it. Check the
value before exporting it, or let the command fail loudly.

**A merge no longer takes your word for it.** `bin/pr-review` asks `gh api user`
**before** any write on the merge path and refuses unless the answer is a GitHub
App installation (`bin/lib/acting_identity.rb`): an App gets 403 "Resource not
accessible by integration", a person gets 200 with a login. It **fails closed**,
and a refusal costs only a re-review. An empty `GH_TOKEN` earns one mint-and-retry
before the refusal stands.

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
export GH_APP_ITEM=github.mcritchie-admin   # BEFORE the push — see below
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
needs neither the broker nor Alex, as long as the `.pem` is on this
machine. Reach for it before you decide the night is over.

A machine that has **never been given** an admin token — no `~/.zprofile.admin`
on disk at all — genuinely needs Alex, once, to run
`bin/setup-1pass-token --admin`. That is the only credential step on either lane
that is his. Everything else here, both lanes included, is yours.

Do not read a deployer refusal as that case without checking for
`~/.zprofile.admin` first; sourcing it is usually the whole fix.

---

## Background — not needed to execute

Why the shared cache exists: the credential helper once re-derived a session
from the private key on every git operation, and a day of ordinary work spent the
account's 1000-read daily quota. Reading the shared session first makes a warm git
operation cost zero reads. The full history is in
[`../archive/token-session-2026-09-25.md`](../archive/token-session-2026-09-25.md).

Deeper reference: `mcritchie-studio/docs/agents/modules/source-control.md`
(architecture, the three credential stores and how they rank) and
`mcritchie-studio/docs/agents/modules/credentials.md` (1Password conventions).
