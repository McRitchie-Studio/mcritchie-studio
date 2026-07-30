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
- **`gh` (and any GitHub API caller)** — export a minted token per session:

  ```bash
  export GH_TOKEN="$(GH_APP_ID="$(op read 'op://agents/github.mcritchie-agent/app-id')" \
    GH_APP_PEM="$(op read 'op://agents/github.mcritchie-agent/mcritchie-agent.2026-07-29.private-key.pem')" \
    bin/gh-app-mint-token)"
  ```

  Swap both `op://` paths to the deployer item for ship lanes. Installation
  tokens expire in **1 hour** — a 403 mid-session means re-mint, not broken
  wiring. Never print the token.

The identities:

| Identity (1Password item) | Lane | Grants |
|---------------------------|------|--------|
| `github.mcritchie-agent` (**default**) | build / review | Contents + Pull requests + Checks read + Actions + Workflows |
| `github.mcritchie-deployer` (`export GH_APP_ITEM=github.mcritchie-deployer`) | ship | Contents + Actions + Checks read + Secrets. **No pull-request scope** — the deployer cannot open or merge PRs by design |

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
