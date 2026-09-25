# Source Control

Everything an agent needs to push, open a PR, read CI, and merge, and to fix its
own credential when that stops working. **The provider is GitHub** (the
`McRitchie-Studio` org). The contract is at the top; the GitHub specifics are
underneath. The rationale and measurements this page no longer carries are frozen
verbatim in [`../archive/source-control-2026-09-25.md`](../archive/source-control-2026-09-25.md).

## ⛔ The standing rule: source-control auth is SELF-SERVICE

**A stale `gh`/`git` credential is never a reason to stop and ask Mr. McRitchie.**
Fix it yourself, in one command, and keep going:

```bash
eval "$(bin/gh-auth-refresh --export)"
```

That is the whole recovery. It resolves this session's lane, refreshes both
stores, verifies by read-back, and prints the identity it installed, never the
token. A GitHub token is not Mr. McRitchie's to hand over: installation tokens are
minted on demand, expire about hourly by design, and every lane re-mints its own.

**Escalate only after** you have run it and read its stderr. Report *what it
said*, not "I need GitHub auth."

| Situation | Yours or his? |
|-----------|---------------|
| Token expired, 401, 403, `gh auth login` prompt, CI unreadable | **Yours.** Run the command above |
| Deployer mint says `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` is not set | **Yours, if you hold the ship lane:** `source ~/.zprofile.admin`, then retry. In any other lane that refusal is the isolation working — stop there |
| `op whoami` fails — 1Password itself is signed out | **His.** Name the command he must run |
| App installation lacks a grant the work genuinely needs | **His.** Name the repo, endpoint, and grant |
| Merging, deploying, or pushing `main` without an assigned lane | **His.** Authority, not credentials |

## Provider Policy

- **One provider is active at a time**, named here. Repo facts live in
  [`app-registry.md`](app-registry.md); 1Password items in [`credentials.md`](credentials.md).
- **Agents never hold a long-lived personal token.** Auth is a short-lived
  credential minted per lane from a secrets store.
- **Identity is per-lane, and the lanes are privilege boundaries**: build and
  review can open and merge PRs; the ship lane cannot, by design.
- **Tools recover themselves** through one mint-and-retry helper.
- **The workflow is provider-neutral.** A second provider needs a credential
  broker answering the `bin/gh-token` contract, a git credential helper, a
  classifier entry in `bin/lib/gh_auth_retry.rb`, a CI adapter, and a section
  here, and **no SOP edits**.

## GitHub — The Current Provider

Every repo lives under the **McRitchie-Studio** org, and `git`/`gh` authenticate
as one of **two GitHub Apps**. Fine-grained PATs are retired: they cannot call the
check-runs API the CI gates read.

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

This is a **privilege boundary, not a preference.** A ship session that installs
the *agent* App has handed itself the merge grant the deployer is denied.
`bin/gh-auth-refresh` honours `GH_APP_ITEM`, so the two legs cannot disagree. If
a `not accessible by integration` ever contradicts the table, re-read the grants
from `GET /app/installations`.

### How the two tools are wired — differently

**`gh` never consults git credential helpers.** That single fact explains most
confusion here.

| Tool | Wiring |
|------|--------|
| **`git`** (https push/fetch) | The global credential helper `bin/gh-app-git-credential` answers from the **shared session** `bin/gh-token` holds, and mints only on a cache miss. Nothing to refresh by hand: a token git rejects comes back as `erase`, which retires that session so the next call mints once |
| **`gh`** (and any API caller) | Reads an ambient credential. **Goes stale hourly.** This is the one you fix |

Wire the git leg once, globally. **Point it at the INSTALLED helper, never at
the copy in the repo** — see the box below:

```bash
bin/install-git-credential-helper      # installs the snapshot, then PRINTS the wiring command
# what it prints — run it as printed:
git config --global --replace-all credential."https://github.com".helper \
  "$HOME/.mcritchie/git-credential/current/bin/gh-app-git-credential" '/gh-app-git-credential$'
```

Both halves are load-bearing. `--replace-all` is needed because the real
`~/.gitconfig` holds two values there (an empty reset, then the helper), and a
plain set exits 5. The value-pattern keeps the empty reset that stops
`osxkeychain` answering github.com, and makes a re-run converge on one value.
Source: `bin/lib/credential_helper_install.rb`.

> **Why not `<repo>/bin/gh-app-git-credential`?** A working tree moves: `git
> checkout` unlinks and recreates files, so a push during a checkout dies with
> `No such file or directory`. The installer copies the helper's closure into
> `~/.mcritchie/git-credential/versions/<digest>/` behind a stable `current`
> symlink. It is a SNAPSHOT, so run `bin/install-git-credential-helper --check`
> and re-install after any change to `bin/gh-token` or the helper. The installer
> never edits `~/.gitconfig`; it prints the change and its revert.

### Three stores, and they rank

`gh` resolves its credential from three **separate** places, in this order:

1. **`GH_TOKEN`** in the environment — **beats everything**
2. **`gh`'s own keyring**
3. the stored fallback

`bin/gh-token`'s cache (`<projects>/.agents/github-tokens.json`) is a **fourth,
separate** store. **None of these refresh each other**, so "I just minted a
token" and "`gh` works" are different claims.

`eval "$(bin/gh-auth-refresh --export)"` is the form that repairs **both** the
keyring and this shell's `GH_TOKEN`. Drop `--export` and it refreshes only the
keyring, then **exits 3** if a set `GH_TOKEN` still shadows the result — because
for that session nothing was actually fixed.

**`eval` hides the exit code — read stderr.** `eval "$(…)"` reports the
`export` builtin's status, and `eval` of an empty string succeeds silently. If
nothing was exported, it failed; the command says what happened on **stderr**.

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

**The liveness probe is `gh api rate_limit`, NOT `gh api user`.** An App token
cannot call `/user` at all, so a healthy token answers `403 Resource not
accessible by integration` there. A 403 on `/user` CONFIRMS App auth.

### The `gh auth login` trap

> **Never pipe the broker into `gh auth login`.** It cannot run while `GH_TOKEN`
> is set (`gh` refuses to store a credential then). Even when it runs, it fixes
> the keyring, which `GH_TOKEN` outranks. And it ignores `GH_APP_ITEM`, so a ship
> session recovering this way installs the **agent** App.

So *asking Mr. McRitchie to run `gh auth login`* is not a fallback either. `gh
auth status` is not safe to paste into a transcript: it prints a token fragment.

### What recovers automatically, and what does not

**Tools should not need a manual refresh.** `bin/lib/gh_auth_retry.rb` classifies
an auth refusal and `bin/gh-token` supplies the replacement, one mint-and-retry per
caller, each in its own lane. `bin/ship`, `bin/pr-review`, and
`bin/lib/ci_status.rb` route through it. **If a *tool* stops on auth, that tool is
missing the wiring**: a bug, not a chore. The manual refresh is for a hand-run `gh`.

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

The transport view of a normal task. The lifecycle itself is
[`../system/devops-cycle-design.md`](../system/devops-cycle-design.md).

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
  pins the base, except on a DELIBERATE STACK (the base is another OPEN PR's
  head), where it leaves the base alone and `bin/pr-review` refuses to merge. On
  a base it cannot judge, `bin/ship` repairs and `bin/pr-review` REFUSES, because
  review's next step is a merge.
- **A pushed branch preserves code; `main` does not.** `main` is for shipped
  integration, not backup.

### The commands, in one place

```bash
eval "$(bin/gh-auth-refresh --export)"      # fix this session's credential; read its stderr
source ~/.zprofile.admin                    # ship lane only: load the admin 1Password token
export GH_APP_ITEM=github.mcritchie-deployer  # ship lane only, BEFORE the push
bin/gh-auth-refresh --force                 # bypass the broker cache (revoked token)
bin/gh-token --status                       # cache state; prints NO token
gh api rate_limit                           # is the credential live?
op whoami                                   # is 1Password unlocked?
```

Do not install the deployer into `gh` with `bin/gh-auth-refresh --identity
deployer`: the script accepts the flag, but the deployer App has no
`pull_requests` grant and `bin/release` calls `gh pr` (prepare's promote), so the next PR call fails.
The two ship-lane lines above are the whole deployer fix
([`token-session.md`](token-session.md#the-deployer-lane--self-service-on-a-provisioned-machine)).

## Commit Authorship — which soul `git log` names

Auth identity answers *may this lane push*. Authorship answers *who wrote this*,
and the two are unrelated. The soul is always the **task's `devops.built_by`**
(the current builder), spelled by `lib/commit_identity.rb` one way everywhere:

```
Carl <carl@mcritchie.studio>      # name titleised from the slug; local part IS the slug
```

It reaches a commit through **two layers**, because a desk commits by two paths:

| Commit path | Identity comes from | Set by |
|---|---|---|
| `bin/ship`'s 1/8 commit | The environment (`GIT_AUTHOR_*`/`GIT_COMMITTER_*`), which outranks every config file | `CommitIdentity.commit!`, from `built_by` at that moment |
| Every other desk commit: your own mid-build commits, a merge-forward, a rebase | The **desk's own** config file, `.git/worktrees/<desk>/config.worktree` | `bin/agent-worktree new --soul <soul>`, which `bin/task begin --agent <soul>` passes |

**Layer 2 exists because layer 1 covers one commit.** Before it, desk hand
commits inherited a shared repo default (`Steffon (Claude)` on turf-monster), and
a reviewer read that default as authorship.

**`bin/task begin` keeps the two layers in step.** It stamps the desk from
`--agent` as it is cut, then reads the recorded `built_by` back after the claim and
re-stamps if they differ, so a hand commit and a ship commit always name the same
soul. With no builder on record it stamps nothing and prints `UNSTAMPED` with the
command to fix it.

**A re-claim repoints both.** `built_by` names the current builder and repoints on
an explicit `--actor`/`--agent`. After `bin/task begin <task> --agent shannon
--steal`, the next ship commit and the desk stamp are both Shannon's, while the
earlier commits stay Carl's. A handoff made OUTSIDE `begin` (`bin/task move <task>
building --actor <soul>`) repoints `built_by` but not the desk, so stamp it too:

```bash
/Users/alex/projects/mcritchie-studio/bin/agent-worktree identity <app> <task-slug> <soul>
```

**A task that names no builder is not given one.** `bin/ship` says so and commits
under the checkout's own identity (the operator's global one), and `begin` leaves
the desk unstamped. An unattributed commit that admits it is recoverable; one
laundered under a guessed soul is not.

**Never a plain `git config user.name` in a desk.** Without `--worktree` that write
lands in the shared `.git/config` and renames every desk in the repo at once.
`bin/agent-worktree identity` is the only sanctioned writer. It refuses a primary
checkout, a value that is not a soul slug, and a repo whose shared config would
change behind someone's back. Its only shared write is
`extensions.worktreeConfig = true`, once per repo.

**A worktree cut FROM a stamped desk inherits the stamp** (git copies
`config.worktree` into the new worktree; measured on git 2.50.1). A zap throwaway
cut from a builder's desk therefore commits as the builder. A reviewer or conductor
zapping from there names themselves per commit: see the
[zap protocol](zap-protocol.md#reviewer--apply-a-bounded-zap-or-name-it).

**Only people and one monitor read git authorship.** `bin/reviewer-select`,
fix-forward, sizing, and the learning heartbeat all read the board, never git, so
the stamp cannot forge or silence the author set review excludes on. The one
machine reader is the `Github::CommitFetcher` builder monitor, which counts fewer
commits, since `<soul>@mcritchie.studio` resolves to no GitHub account.

## Where To Read Next

| Need | Read |
|------|------|
| 1Password item names, fields, the `.pem` attachment | [`credentials.md`](credentials.md) |
| Full credential inventory | [`credential-inventory.md`](credential-inventory.md) |
| The lifecycle these commands serve | [`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) |
| CI verdicts and the gates | [`gates/g2-review.md`](gates/g2-review.md) |
| Deploys and env | [`deployment.md`](deployment.md) |
