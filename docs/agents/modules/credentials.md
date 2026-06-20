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

`gh` and `git push` authenticate as `amcritchie` via a fine-grained PAT stored in
1Password (`agent.github` in the `agents` vault). **If you hit a `403` /
"Permission denied" on `git push`, a PR merge, or any `gh` write**, the keyring
token is missing, stale, or read-only — re-wire it from 1Password (the token is
piped, never printed):

```bash
op read "op://agents/agent.github/personal-access-token-read-write-2026" \
  | gh auth login -h github.com --with-token
gh auth setup-git -h github.com   # make gh the git credential helper
```

Confirm with a **real** read/write — not the repo permissions API, which reflects
the *account's* access, not the *token's* grant (this once masked a read-only
token): `gh pr list` for read, a throwaway branch `git push` for write. The PAT
grants Contents / Pull requests / Workflows read+write + Actions / Commit
statuses read. Rotate before its GitHub expiry: regenerate, replace the 1Password
field, and re-run the command above.

## Fresh Machine

On a wiped machine:

1. Clone `mcritchie-studio`.
2. Run `bin/ecosystem-build` until it stops at the 1Password token step.
3. Copy the service account token to the clipboard.
4. Run `bin/setup-1pass-token`.
5. Re-run `bin/ecosystem-build`.

The full recovery path lives in [`../system/house-burn-down.md`](../system/house-burn-down.md).
