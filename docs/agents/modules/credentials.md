# Credentials

Credential docs are split into two layers:

- This file defines how agents may access credentials.
- [`credential-inventory.md`](credential-inventory.md) lists known item names and references without exposing secret values.

## Contract

- Never print secrets into the terminal or transcript.
- Use `/opt/homebrew/bin/op` directly for targeted reads.
- Prefer repo scripts that write or consume secrets without echoing them.
- Do not scan vaults broadly unless Mr. McRitchie explicitly asks.
- Do not edit agent tool permissions or `.claude/settings*.json` to gain credential access.
- If a permission is missing, report the exact vault, item, and operation needed instead of inventing a workaround.

## 1Password Service Account

Agent shells use `OP_SERVICE_ACCOUNT_TOKEN` from `~/.zprofile`, installed by:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/setup-1pass-token
```

Verify:

```bash
/opt/homebrew/bin/op whoami
```

Expected user type: `SERVICE_ACCOUNT`.

Default access is the `agents` vault. Additional vaults should be granted deliberately for a role or task, such as a DevOps-specific vault for AWS credentials.

## GitHub (`gh` / `git`)

Since the 2026-07-29 org migration every repo lives under the **McRitchie-Studio**
org and `git`/`gh` authenticate as one of **two GitHub Apps**, not a personal
token — but the two tools take **different wiring** (`gh` never consults git
credential helpers):

- **`git` (https push/fetch)** — the global credential helper
  `mcritchie-studio/bin/gh-app-git-credential` mints a fresh installation token
  per call (via `bin/gh-app-mint-token`); the `GH_APP_ITEM` env var selects the
  identity.
- **`gh` (and any GitHub API caller)** — export a minted token per session, by
  asking that same helper for one:

  ```bash
  export GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | \
    /Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential get | \
    sed -n 's/^password=//p')
  ```

  **One recipe, both legs.** This is the canonical form, and it is the string
  `bin/release` prints when a `gh` call fails on credentials
  (`Release::GhFailure`) — so the tool's advice and this doc cannot drift. It
  beats calling `bin/gh-app-mint-token` by hand on three counts: it selects the
  identity through **`GH_APP_ITEM`**, exactly as `git` does, so the two legs can
  never disagree; it finds the `.pem` attachment **by suffix**, so no key
  filename is baked in to rot at the next rotation; and the absolute path works
  from any directory. For a ship lane, `export GH_APP_ITEM=github.mcritchie-deployer`
  **first** — the same export already governs `git`. Never print the token.

  Installation tokens live **1 hour**, and the two credential faults look
  different — same remedy, different mechanism:

  | Symptom | Mechanism | Fix |
  |---------|-----------|-----|
  | **401 `Bad credentials`** | `GH_TOKEN` is set but **expired** — it is sent and rejected | Re-mint (above) |
  | **403 `not accessible by personal access token`** | `GH_TOKEN` is **unset or empty**, so `gh` never sends it and falls back to the stored PAT, which lacks the scope | Re-mint (above) |
  | **403 `not accessible by integration`** | The token is **live**; the App installation lacks the grant — **unless the endpoint is closed to Apps entirely** (see the probe note below) | **`unset GH_APP_ITEM`**, then re-mint — a fresh token for the same identity fails identically |
  | **404 `Could not resolve to a Repository`** | GitHub reports a repo the token may not **see** as one that does not **exist** | Confirm the name (`gh repo view <owner>/<name>`), then re-mint |

  **The liveness probe is `gh api rate_limit`, NOT `gh api user`.** An App
  installation token cannot call `/user` **at all** — Apps are forbidden from it
  by design — so a perfectly healthy token answers `403 Resource not accessible
  by integration` there. A 403 on `/user` therefore **CONFIRMS** App auth; it
  does not diagnose a fault, and reading it as one sends you chasing a grant that
  cannot exist. `gh api rate_limit` answers for every identity, so it is the
  probe that can actually tell live from stale.

  **Two stores — and nothing refreshes the second one.** `bin/gh-token`'s cache
  (`<projects>/.agents/github-tokens.json`) and **`gh`'s own keyring** are
  SEPARATE. Minting refreshes the cache; the keyring is left where it was. So an
  interactive `gh` goes stale roughly hourly *while the cache is fresh*, and any
  tool reading GitHub through the ambient credential starts reporting a
  credential fault on a repo it read fine an hour ago. Refresh the keyring from
  the same broker (never print the token):

  ```bash
  bin/gh-token | gh auth login -h github.com --with-token
  ```

  **Tools should not need that.** `bin/lib/gh_auth_retry.rb` classifies the
  refusal and `bin/gh-token` supplies the replacement, giving any caller one
  mint-and-retry; `bin/ship`, `bin/pr-review`, and `bin/lib/ci_status.rb` (every
  CI read the gates make) all route through it. The manual refresh above is for
  an interactive `gh` in a terminal — if a *tool* ever needs it, that tool is
  missing the wiring, which is the bug task `standardize-ci-read-auth` fixed for
  the CI reads.

The identities:

| Identity (1Password item) | Lane | Grants |
|---------------------------|------|--------|
| `github.mcritchie-agent` (**default**) | build / review | Contents write + **Pull requests write** + Checks read + Actions write + Workflows write + Administration write + Metadata/Statuses read |
| `github.mcritchie-deployer` (`export GH_APP_ITEM=github.mcritchie-deployer`) | ship | Contents write + Actions write + Checks read + Secrets write + Administration write + Metadata/Statuses read. **No `pull_requests` grant at all** — the deployer cannot open or merge PRs by design |

Grants above are the installations' live permission sets, read 2026-08-12 from
`GET /app/installations`. Re-read them there rather than trusting this table if a
`not accessible by integration` ever disagrees with it.

Wire it (global, one time):

```bash
git config --global credential."https://github.com".helper \
  "/Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential"
```

Each item carries fields `app-id` and `client-id`; the private key is the
**`.pem` FILE attachment** on the item — the concealed `private key` field is
NOT the key. Confirm access with a **real** read/write — not the repo
permissions API, which reflects the *account's* access, not the *token's* grant
(this once masked a read-only token): `gh pr list` for read, a throwaway branch
`git push` for write.

**Historical — the PAT era.** Until 2026-07-29 auth was a fine-grained PAT on
the `amcritchie` personal account (`agent.github`, wired via `gh auth login
--with-token` + `gh auth setup-git`). Fine-grained PATs cannot call the
check-runs API at all — which the CI gates read — so the PAT wiring is retired;
`agent.github` is deprecated pending deletion.

## Fresh Machine

On a wiped machine:

1. Clone `mcritchie-studio`.
2. Run `bin/ecosystem-build` until it stops at the 1Password token step.
3. Copy the service account token to the clipboard.
4. Run `bin/setup-1pass-token`.
5. Re-run `bin/ecosystem-build`.

The full recovery path lives in [`../system/house-burn-down.md`](../system/house-burn-down.md).
