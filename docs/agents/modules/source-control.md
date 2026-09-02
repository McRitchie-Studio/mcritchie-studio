# Source Control

Everything an agent needs to push, open a PR, read CI, and merge — and to fix
its own credential when that stops working. **The provider is currently GitHub**
(the `McRitchie-Studio` org). This file is written so a second provider could be
added without rewriting the workflow around it: the contract lives at the top,
the GitHub specifics underneath.

## ⛔ The standing rule: source-control auth is SELF-SERVICE

**A stale `gh`/`git` credential is never a reason to stop and ask Mr. McRitchie.**
Fix it yourself, in one command, and keep going:

```bash
eval "$(bin/gh-auth-refresh --export)"
```

That is the whole recovery. It resolves this session's lane, refreshes both
stores, verifies by read-back, and prints the identity it installed — never the
token.

This rule exists because the general First Rule — *"ask Mr. McRitchie for
approvals, **credentials**, product judgment, or external access"* — reads as
though a GitHub token were his to hand over. **It is not.** Installation tokens
are minted on demand from 1Password by a script built for exactly this, they
expire about hourly by design, and every agent lane can re-mint its own. Handing
that upward is the terminal chore the same rule forbids.

The failure mode this replaces, observed repeatedly: an agent mid-`pr-review`
hits `Bad credentials`, reads "credentials" as an escalation category, and stops
a whole review wave to ask for a manual `gh auth login` — which, run as asked,
**would not have worked** (see *The `gh auth login` trap* below).

**Escalate only after** `eval "$(bin/gh-auth-refresh --export)"` has been run and
its stderr read. If it fails, the useful report is *what it said*, not "I need
GitHub auth."

| Situation | Yours or his? |
|-----------|---------------|
| Token expired, 401, 403, `gh auth login` prompt, CI unreadable | **Yours.** Run the command above |
| Deployer mint says `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` is not set | **Yours, if you hold the ship lane:** `source ~/.zprofile.admin`, then retry. In any other lane that refusal is the isolation working — stop there |
| `op whoami` fails — 1Password itself is signed out | **His.** Name the command he must run |
| App installation lacks a grant the work genuinely needs | **His.** Name the repo, endpoint, and grant |
| Merging, deploying, or pushing `main` without an assigned lane | **His.** Authority, not credentials |

## Provider Policy

- **One provider is active at a time**, and the ecosystem names it here. Today
  that is GitHub. Repo-level facts (which repos exist, which ports they take)
  stay in [`app-registry.md`](app-registry.md); 1Password item names, fields,
  and attachments stay in [`credentials.md`](credentials.md).
- **Agents never hold a long-lived personal token.** Auth is a short-lived
  credential minted per lane from a secrets store. A provider that cannot do
  that does not meet the contract.
- **Identity is per-lane, and the lanes are privilege boundaries** — the build /
  review lane can open and merge PRs; the ship lane cannot, by design. A
  provider must express that split as separate credentials, not as etiquette.
- **Tools recover themselves.** Any script making a provider API call routes
  through one mint-and-retry helper rather than growing its own. Adding a
  provider means teaching that helper, not teaching N scripts.
- **The workflow is provider-neutral**; only the transport is not. The branch
  ladder (`accepted → release → main`), the gates, and the task lifecycle are
  defined in [`../system/devops-cycle-design.md`](../system/devops-cycle-design.md)
  and do not mention GitHub. Swapping providers should touch *this* file, the
  credential scripts, and CI — not the SOPs.

## GitHub — The Current Provider

Since the **2026-07-29 org migration** every repo lives under the
**McRitchie-Studio** org, and `git`/`gh` authenticate as one of **two GitHub
Apps**. Fine-grained PATs are retired: they cannot call the check-runs API at
all, which the CI gates read.

### At a glance

| | |
|---|---|
| **Org** | `McRitchie-Studio` (was the `amcritchie` personal account until 2026-07-29) |
| **Credential** | GitHub **App installation token**, ~**1 hour** lifetime |
| **Where it comes from** | 1Password (`studio-agents` for the agent lane, `studio-agents-admin` for the deployer — `bin/lib/op_vaults.rb` is the map) → `bin/gh-app-mint-token`, brokered by `bin/gh-token` |
| **Refresh** | `eval "$(bin/gh-auth-refresh --export)"` |
| **Liveness probe** | `gh api rate_limit` — **never** `gh api user` |
| **PR base** | `accepted` — never `release`, never `main` |

### The two identities

The lane picks the identity through **`GH_APP_ITEM`**; precedence is
`--identity` > `GH_APP_ITEM` > `agent`.

| Identity (1Password item) | Lane | Can it touch PRs? |
|---------------------------|------|-------------------|
| `github.mcritchie-agent` (**default**) | build / review | **Yes** — Contents + **Pull requests** + Checks read + Actions + Workflows + Administration |
| `github.mcritchie-deployer` (`export GH_APP_ITEM=github.mcritchie-deployer`) | ship | **No `pull_requests` grant at all** — the deployer cannot open or merge PRs, by design. Contents + Actions + Checks read + Secrets + Administration |

The two items live in different vaults, read by different tokens: the agent's in
`studio-agents` (`OP_SERVICE_ACCOUNT_TOKEN`, every shell), the deployer's in
`studio-agents-admin` (`OP_ADMIN_SERVICE_ACCOUNT_TOKEN`, loaded only by `source
~/.zprofile.admin`). A ship session sources that profile **before** exporting
`GH_APP_ITEM`; an ordinary agent shell cannot read the deployer at all.

This is a **privilege boundary, not a preference.** A ship session that recovers
its credential carelessly and installs the *agent* App has handed itself the
merge grant the deployer is denied on purpose — which is precisely what the old
recovery advice did. `bin/gh-auth-refresh` honours `GH_APP_ITEM`, so the two
legs cannot disagree.

Grants above were read 2026-08-12 from `GET /app/installations`. If a
`not accessible by integration` ever contradicts this table, re-read it there
rather than trusting the table.

### How the two tools are wired — differently

**`gh` never consults git credential helpers.** That single fact explains most
confusion here.

| Tool | Wiring |
|------|--------|
| **`git`** (https push/fetch) | The global credential helper `bin/gh-app-git-credential` answers from the **shared session** `bin/gh-token` holds, and mints only on a cache miss. Nothing to refresh BY HAND — a token git rejects comes back to the helper as `erase`, which retires that one session so the next call mints once. (It minted per call until 2026-08-29; that cost three 1Password reads per git operation and once spent the daily quota.) |
| **`gh`** (and any API caller) | Reads an ambient credential. **Goes stale hourly.** This is the one you fix |

Wire the git leg once, globally:

```bash
git config --global credential."https://github.com".helper \
  "/Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential"
```

### Three stores, and they rank

`gh` resolves its credential from three **separate** places, in this order:

1. **`GH_TOKEN`** in the environment — **beats everything**
2. **`gh`'s own keyring**
3. the stored fallback

`bin/gh-token`'s cache (`<projects>/.agents/github-tokens.json`) is a **fourth,
separate** thing — the broker's two-slot cache, which minting refreshes. **None
of these refresh each other**, which is why an interactive `gh` goes stale
roughly hourly while the broker cache reads perfectly fresh, and why "I just
minted a token" and "`gh` works" are different claims.

`eval "$(bin/gh-auth-refresh --export)"` is the form that repairs **both** the
keyring and this shell's `GH_TOKEN`. Drop `--export` and it refreshes only the
keyring, then **exits 3** if a set `GH_TOKEN` still shadows the result — because
for that session nothing was actually fixed.

**`eval` hides the exit code — read stderr.** `eval "$(…)"` reports the `export`
builtin's status, not the command's, so the 0/1/3 contract is invisible in the
very form prescribed here. If nothing was exported, it failed: `eval` of an empty
string succeeds silently and leaves the stale token in place. The command says
what happened on **stderr** either way.

### Symptom → fix

Every row's fix starts with `eval "$(bin/gh-auth-refresh --export)"`. The column
that matters is *what else*.

| Symptom | Mechanism | What else |
|---------|-----------|-----------|
| **401 `Bad credentials`** | `GH_TOKEN` is set but **expired** — sent and rejected | Nothing. Re-mint and retry |
| **403 `not accessible by personal access token`** | `GH_TOKEN` is **unset/empty**, so `gh` fell back to the stored PAT, which lacks the scope | Nothing. Re-mint and retry |
| **403 `not accessible by integration`** | Token is **live**; the installation lacks the grant — *unless the endpoint is closed to Apps entirely* | **`unset GH_APP_ITEM`** first, then re-mint. A fresh token for the same identity fails identically |
| **404 `Could not resolve to a Repository`** | GitHub reports a repo the token cannot **see** as one that does not **exist** | Confirm the name: `gh repo view <owner>/<name>` |
| **`gh auth login` prompt / "requires authentication"** | No accepted credential reached GitHub at all | Confirm 1Password is unlocked: `op whoami` |
| **Broker says fresh, GitHub still refuses** | The cache is **age-based**; a *revoked* token still reads as fresh | `bin/gh-auth-refresh --force` bypasses the cache |

**The liveness probe is `gh api rate_limit`, NOT `gh api user`.** An App
installation token **cannot call `/user` at all** — Apps are forbidden from it by
design — so a perfectly healthy token answers `403 Resource not accessible by
integration` there. A 403 on `/user` **CONFIRMS** App auth; it does not diagnose
a fault, and reading it as one sends you chasing a grant that cannot exist.

### The `gh auth login` trap

> **Never pipe the broker into `gh auth login`.** The retired advice was
> `bin/gh-token | gh auth login -h github.com --with-token`, and it is broken in
> exactly the configuration these docs create:
>
> 1. **It cannot run when `GH_TOKEN` is set.** `gh` refuses to store a credential
>    while `GH_TOKEN` is in the environment — exit 1, keyring untouched (measured
>    on gh 2.92.0). The one instruction a blocked agent was handed is refused
>    outright, and re-running never helps.
> 2. **Even when it runs, it fixes the wrong store.** `GH_TOKEN` outranks the
>    keyring, so a session with an expired export keeps sending the expired token
>    no matter how fresh the keyring becomes.
> 3. **It crossed a privilege boundary.** It ignored `GH_APP_ITEM`, so a **ship**
>    session recovering this way installed the **agent** App.

This is also why *asking Mr. McRitchie to run `gh auth login`* is not a fallback:
it is the same broken step, executed by a more expensive operator. `gh auth
status` is likewise not safe to paste into a transcript — it prints a leading
token fragment by default.

### What recovers automatically, and what does not

**Tools should not need a manual refresh.** `bin/lib/gh_auth_retry.rb` classifies
an auth refusal and `bin/gh-token` supplies the replacement, giving any caller
one mint-and-retry, each recovering **as its own lane**. `bin/ship`,
`bin/pr-review`, and `bin/lib/ci_status.rb` (every CI read the gates make) route
through it.

So: **if a *tool* stops on auth, that tool is missing the wiring** — that is a
bug in the tool, not a chore for the operator. The manual refresh is for an
interactive `gh` in a terminal, and for the seam where an agent runs `gh` by hand.

### Secret hygiene

- **Never print a token.** Report a **SHA-256 prefix** instead — what
  `bin/gh-auth-refresh` does.
- **`.` and `-` are part of the token.** An installation token is a dotted JWT
  (`ghs_<base64>.<base64>.<signature>`, ~380 chars). The obvious redaction
  `ghs_[A-Za-z0-9_]*` **stops at the first dot** and passes the rest through, so
  a "redacted" line can still carry the whole credential. Use
  `gh[psou]_[A-Za-z0-9_.-]+`.
- Verify a token by **length and 4-character prefix** only.
- **If a token reaches a transcript it is compromised.** Revoke immediately:
  `curl -X DELETE https://api.github.com/installation/token -H "Authorization: Bearer $TOKEN"`
  (HTTP 204), then `bin/gh-auth-refresh --force`.

## Usage In The Standard Workflow

Where source control actually shows up in a normal task, and who does what. The
authority for the lifecycle itself is
[`../system/devops-cycle-design.md`](../system/devops-cycle-design.md); this is
the transport view.

| Step | Command | Lane | Identity |
|------|---------|------|----------|
| Cut a desk | `bin/agent-worktree new <app> <task>` | build | — (local) |
| Push the branch | handled inside `bin/ship` | build | agent (git helper) |
| Open the PR — **base `accepted`** | handled inside `bin/ship` | build | agent |
| Read CI | `bin/lib/ci_status.rb` via the gates | build / review | agent |
| Merge to `accepted` | `gh pr merge` in `pr-review` | review | agent |
| Promote `accepted → release` | `bin/release prepare` | QA | agent |
| Fast-forward `release → main` | `bin/release ship` | **ship** | **deployer** |

Two rules that are about source control, not process:

- **Feature PRs target `accepted`.** Never `release`, never `main`. `bin/ship`
  pins the base for you.
- **A pushed branch preserves code; `main` does not.** `main` is for shipped
  integration, not backup.

### The commands, in one place

```bash
source ~/.zprofile.admin                    # ship lane only: load the admin 1Password token
eval "$(bin/gh-auth-refresh --export)"      # fix this session's credential
bin/gh-auth-refresh --identity deployer     # force the ship identity
bin/gh-auth-refresh --force                 # bypass the broker cache (revoked token)
bin/gh-token --status                       # cache state; prints NO token
gh api rate_limit                           # is the credential live?
op whoami                                   # is 1Password unlocked?
```

## Adding A Second Provider

The seam is deliberately narrow. A new provider needs: a credential broker
answering the `bin/gh-token` contract (per-lane, short-lived, cached on disk
because agents are separate processes), a git credential helper, a classifier
entry in `bin/lib/gh_auth_retry.rb`, a CI adapter, and a section in this file.
It should need **no SOP edits** — if it does, a SOP has leaked transport detail
and that is the thing to fix first.

## Where To Read Next

| Need | Read |
|------|------|
| 1Password item names, fields, the `.pem` attachment | [`credentials.md`](credentials.md) |
| Full credential inventory | [`credential-inventory.md`](credential-inventory.md) |
| The lifecycle these commands serve | [`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) |
| CI verdicts and the gates | [`gates/g2-review.md`](gates/g2-review.md) |
| Deploys and env | [`deployment.md`](deployment.md) |
